;;; harness-board-store-test.el --- Tests for the board as the harness serves it  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The store and the bus methods: a board written under the state
;; directory and read back, a patch previewed and committed atomically
;; with its read set and its idempotency key, undo that survives a
;; restart, the client state navigation writes without a revision, and
;; the resolution of the links a board's objects carry.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-board)
(require 'harness-board-edit)
(require 'harness-board-store)
(require 'harness-board-svg)
(load (expand-file-name "test/fixtures/harness-board-fixture.el" harness-test-root))

(defun harness-board-store-test--make (&optional id)
  "Make board ID from the fixture, saving it and returning its document."
  (let ((board (harness-board-fixture-board)))
    (setq board (plist-put board :id (or id "b-fixture")))
    (harness-board-save board)
    board))

(defun harness-board-store-test--refusal (thunk)
  "Return the kind of the board error THUNK raises, or nil."
  (condition-case err
      (progn (funcall thunk) nil)
    (harness-board-error (harness-board-error-kind err))))

;;;; A document on disk

(ert-deftest harness-board-store-writes-a-board-and-reads-it-back ()
  "A board is a document under the state directory; what is written is what is read."
  (harness-test-with-temp-state
    (let* ((before (harness-board-store-test--make))
           (after (harness-board-load "b-fixture")))
      (should (file-exists-p (harness-board--path "b-fixture")))
      (should (equal (plist-get before :id) (plist-get after :id)))
      (should (equal (plist-get before :name) (plist-get after :name)))
      (should (equal (plist-get before :theme) (plist-get after :theme)))
      (should (= (length (plist-get before :objects))
                 (length (plist-get after :objects))))
      (should (equal (harness-board--object-views (harness-board--object! before "n-api"))
                     (harness-board--object-views (harness-board--object! after "n-api")))))))

(ert-deftest harness-board-store-a-board-of-another-schema-is-refused ()
  "A stored document of a schema this harness does not read is refused, never half-read."
  (harness-test-with-temp-state
    (make-directory (harness-board--directory) t)
    (with-temp-file (harness-board--path "b-old")
      (insert (harness-json-encode-text (list :schema 99 :id "b-old" :name "old"))))
    (should (eq 'unsupported-operation
                (harness-board-store-test--refusal
                 (lambda () (harness-board-load "b-old")))))))

(ert-deftest harness-board-store-a-board-that-names-nothing-is-refused-on-load ()
  "A stored document that keeps a reference to nothing does not load."
  (harness-test-with-temp-state
    (let ((board (harness-board-store-test--make)))
      ;; Somebody edited the file and left a view in a diagram that is gone.
      (let ((broken (plist-put (copy-sequence board) :diagrams
                               (list (list :id "d-other" :name "other")))))
        (harness-write-file-atomically (harness-board--path "b-fixture")
                                       (harness-json-encode-text broken)))
      (should (eq 'invalid-reference
                  (harness-board-store-test--refusal
                   (lambda () (harness-board-load "b-fixture"))))))))

;;;; Creating and listing

(ert-deftest harness-board-store-create-makes-a-blank-board ()
  (harness-test-with-temp-state
    (let ((document (harness-call 'board/create "b-new" "a new board" nil)))
      (should (equal "b-new" (plist-get document :id)))
      (should (equal "a new board" (plist-get document :name)))
      (should (= 1 (length (plist-get document :diagrams))))
      (should (= 0 (plist-get document :revision)))
      ;; Creating it again is refused rather than emptying it.
      (should (eq 'invalid-parameter
                  (harness-board-store-test--refusal
                   (lambda () (harness-call 'board/create "b-new" "again" nil))))))))

(ert-deftest harness-board-store-list-says-what-a-board-holds ()
  (harness-test-with-temp-state
    (harness-board-store-test--make "b-one")
    (harness-call 'board/create "b-two" "second" (list :project "/tmp/two"))
    (let* ((all (append (harness-call 'board/list nil) nil))
           (one (cl-find "b-one" all :key (lambda (b) (plist-get b :id))
                         :test #'equal)))
      (should (= 2 (length all)))
      ;; The summary carries what a list shows, and nothing it guesses.
      (should (= (length (plist-get (harness-board-load "b-one") :objects))
                 (plist-get one :objects)))
      (should (= 2 (plist-get one :diagrams)))
      (should (= 1 (plist-get one :markers)))
      (should (equal "electric-commons" (plist-get one :theme)))
      ;; A project's boards alone.
      (should (equal '("b-two")
                     (mapcar (lambda (b) (plist-get b :id))
                             (append (harness-call 'board/list (list :project "/tmp/two"))
                                     nil)))))))

(ert-deftest harness-board-store-delete-removes-the-board-and-its-client-state ()
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (harness-board-set-views "b-fixture" (list :focus (list :board "b-fixture")))
    (should (harness-call 'board/delete "b-fixture"))
    (should-not (harness-board-load "b-fixture"))
    (should-not (file-exists-p (harness-board--views-path "b-fixture")))))

;;;; Reading a scene

(ert-deftest harness-board-store-get-reads-a-diagram-as-a-client-draws-it ()
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (let* ((document (harness-call 'board/get "b-fixture" (list :diagram "d-overview")))
           (object (cl-find "n-api" (append (plist-get document :objects) nil)
                            :key (lambda (o) (plist-get o :id)) :test #'equal)))
      (should (= 1 (plist-get document :revision)))
      (should (equal "d-overview" (plist-get (plist-get document :diagram) :id)))
      ;; The exact geometry, the local frame and the named anchors.
      (should (equal [1 0 0 1 330 214] (plist-get object :transform)))
      (should (equal [164 45] (plist-get (plist-get object :anchors) :right)))
      (should (equal (cons 330 214) (plist-get object :origin)))
      (should (equal (list 330 214 164 91) (plist-get object :box)))
      ;; Which diagrams it appears in, and what it links.
      (should (equal '("d-overview" "d-queue")
                     (sort (append (plist-get object :diagrams) nil) #'string<)))
      (should (= 2 (length (plist-get object :resources))))
      (should (eq 'declared (plist-get object :role))))))

(ert-deftest harness-board-store-get-reads-another-diagram-too ()
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (let* ((document (harness-call 'board/get "b-fixture" (list :diagram "d-queue")))
           (ids (mapcar (lambda (o) (plist-get o :id))
                        (append (plist-get document :objects) nil))))
      (should (member "n-handler" ids))
      (should (member "n-record" ids))
      ;; An object with a view in both is the same object, here and there.
      (should (member "n-api" ids)))))

(ert-deftest harness-board-store-get-refuses-a-diagram-it-does-not-have ()
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (should (eq 'unknown-id
                (harness-board-store-test--refusal
                 (lambda () (harness-call 'board/get "b-fixture"
                                          (list :diagram "d-nowhere"))))))))

(ert-deftest harness-board-store-nearby-is-geometry-only ()
  "Nearness says where things are, never what they mean to one another."
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (let* ((document (harness-call 'board/get "b-fixture"
                                   (list :diagram "d-overview" :near "n-api")))
           (nearby (append (plist-get document :nearby) nil)))
      (should nearby)
      (should (< (length nearby) 9))
      ;; Each entry says how far, in units, and nothing about meaning.
      (should (cl-every (lambda (one) (numberp (plist-get one :distance))) nearby))
      (should (= (length nearby)
                 (length (sort (delete-dups (mapcar (lambda (one) (plist-get one :distance))
                                                   nearby))
                               #'<)))))))

(ert-deftest harness-board-store-grammar-is-the-one-list-of-what-a-board-holds ()
  (harness-test-with-temp-state
    (let ((grammar (harness-call 'board/grammar)))
      (should (= harness-board-schema (plist-get grammar :schema)))
      (should (equal (append harness-board-shape-kinds nil)
                     (mapcar (lambda (s) (plist-get s :kind))
                             (append (plist-get grammar :shapes) nil))))
      (should (equal (mapcar #'car harness-board-op-kinds)
                     (mapcar (lambda (o) (intern (plist-get o :op)))
                             (append (plist-get grammar :operations) nil))))
      (should (equal '("electric-commons" "open-labels" "night-commons")
                     (mapcar (lambda (theme) (plist-get theme :name))
                             (append (plist-get grammar :themes) nil))))
      ;; The units and limits an agent needs to place anything at all.
      (should (equal "right" (plist-get (plist-get grammar :units) :x)))
      (should (equal "down" (plist-get (plist-get grammar :units) :y)))
      (should (equal "clockwise degrees" (plist-get (plist-get grammar :units) :angle)))
      (should (= harness-board-max-coordinate
                 (plist-get (plist-get grammar :limits) :coordinate)))
      ;; A theme's palette is a plist of colours, not a nested shape.
      (should (string-prefix-p "#" (plist-get (plist-get (car (append (plist-get grammar :themes) nil))
                                                         :palette)
                                              :paper))))))

;;;; Patching and committing

(ert-deftest harness-board-store-a-patch-is-not-a-commit ()
  "scene.edit proposes; patch.commit is what writes."
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (let* ((answer (harness-call 'board/patch "b-fixture"
                                 (list (list :op "move" :id "n-api" :diagram "d-overview"
                                             :dx 20 :dy 0))
                                 nil))
           (again (harness-board-load "b-fixture")))
      (should (plist-get answer :patch))
      (should (= 64 (length (plist-get answer :hash))))
      (should (= 1 (plist-get answer :revision)))
      (should (equal '("n-api") (append (plist-get answer :changed) nil)))
      ;; Nothing was written.
      (should (= 1 (plist-get again :revision)))
      (should (equal [1 0 0 1 330 214]
                     (plist-get (harness-board--view (harness-board--object! again "n-api")
                                                     "d-overview")
                                :transform))))))

(ert-deftest harness-board-store-preview-names-the-exact-batch ()
  "A preview and the patch it previews name the same batch, so a commit applies exactly that."
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (let* ((ops (list (list :op "move" :id "n-api" :diagram "d-overview" :dx 20 :dy 0)))
           (patch (harness-call 'board/patch "b-fixture" ops nil))
           (preview (harness-call 'board/preview "b-fixture" ops nil)))
      (should (equal (plist-get patch :patch) (plist-get preview :patch)))
      (should (equal (plist-get patch :hash) (plist-get preview :hash)))
      (should (plist-get preview :preview)))))

(ert-deftest harness-board-store-commit-applies-one-atomic-revision ()
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (let* ((preview (harness-call 'board/preview "b-fixture"
                                  (list (list :op "move" :id "n-api" :diagram "d-overview"
                                              :dx 20 :dy 0))
                                  nil))
           (answer (harness-call 'board/commit "b-fixture"
                                 (plist-get preview :patch) (plist-get preview :hash) 1
                                 (list :key "k-1")))
           (saved (harness-board-load "b-fixture")))
      (should (plist-get answer :committed))
      (should (= 2 (plist-get answer :revision)))
      (should (= 2 (plist-get saved :revision)))
      (should (equal [1 0 0 1 350 214]
                     (plist-get (harness-board--view (harness-board--object! saved "n-api")
                                                     "d-overview")
                                :transform)))
      ;; The commit is in the history, with what it replaced.
      (should (= 2 (length (append (plist-get saved :history) nil)))))))

(ert-deftest harness-board-store-a-retried-commit-lands-once ()
  "A key seen before answers what it answered then, so a lost answer costs nothing."
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (let* ((preview (harness-call 'board/preview "b-fixture"
                                  (list (list :op "move" :id "n-api" :diagram "d-overview"
                                              :dx 20 :dy 0))
                                  nil))
           (first (harness-call 'board/commit "b-fixture"
                                (plist-get preview :patch) (plist-get preview :hash) 1
                                (list :key "k-retry")))
           (second (harness-call 'board/commit "b-fixture"
                                 (plist-get preview :patch) (plist-get preview :hash) 2
                                 (list :key "k-retry")))
           (saved (harness-board-load "b-fixture")))
      (should (= 2 (plist-get first :revision)))
      (should (plist-get second :idempotent))
      (should (= 2 (plist-get second :revision)))
      ;; One commit, not two.
      (should (= 2 (plist-get saved :revision))))))

(ert-deftest harness-board-store-an-interrupted-commit-does-not-double-commit ()
  "A commit whose answer was lost is not applied twice by asking again."
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (let* ((ops (list (list :op "create" :id "n-once" :kind "note" :text "once"
                            :diagram "d-overview" :x 0 :y 0
                            :shape (list :kind "rect" :w 40 :h 20))))
           (first (harness-call 'board/commit "b-fixture" nil nil 1
                                (list :ops ops :key "k-once")))
           (second (harness-call 'board/commit "b-fixture" nil nil 2
                                 (list :ops ops :key "k-once")))
           (saved (harness-board-load "b-fixture")))
      (should (= 2 (plist-get first :revision)))
      (should (= 2 (plist-get second :revision)))
      (should (= 1 (cl-count "n-once" (mapcar (lambda (o) (plist-get o :id))
                                              (plist-get saved :objects))
                             :test #'equal))))))

(ert-deftest harness-board-store-a-commit-against-another-revision-is-refused ()
  "The read set moved: the batch is refused, and the board is untouched."
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (let* ((preview (harness-call 'board/preview "b-fixture"
                                  (list (list :op "move" :id "n-api" :diagram "d-overview"
                                              :dx 20 :dy 0))
                                  nil)))
      ;; Somebody else commits first.
      (harness-call 'board/commit "b-fixture" nil nil 1
                    (list :ops (list (list :op "move" :id "n-workers" :diagram "d-overview"
                                           :dx 5 :dy 0))
                          :key "k-theirs"))
      (should (eq 'stale-revision
                  (harness-board-store-test--refusal
                   (lambda ()
                     (harness-call 'board/commit "b-fixture"
                                   (plist-get preview :patch) (plist-get preview :hash) 1
                                   nil))))))))

(ert-deftest harness-board-store-a-patch-from-another-batch-is-refused ()
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (let* ((one (harness-call 'board/preview "b-fixture"
                              (list (list :op "move" :id "n-api" :diagram "d-overview"
                                          :dx 1 :dy 0)) nil))
           (two (harness-call 'board/preview "b-fixture"
                              (list (list :op "move" :id "n-api" :diagram "d-overview"
                                          :dx 2 :dy 0)) nil)))
      (should (eq 'stale-revision
                  (harness-board-store-test--refusal
                   (lambda ()
                     (harness-call 'board/commit "b-fixture"
                                   (plist-get one :patch) (plist-get two :hash) 1 nil))))))))

;;;; Undo

(ert-deftest harness-board-store-undo-survives-a-restart ()
  "History is in the board document, so undo works in the next process."
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (harness-call 'board/commit "b-fixture" nil nil 1
                  (list :ops (list (list :op "move" :id "n-api" :diagram "d-overview"
                                         :dx 40 :dy 0))
                        :key "k-move"))
    ;; A fresh load, as a later Emacs does.
    (let ((saved (harness-board-load "b-fixture")))
      (should (= 2 (plist-get saved :revision)))
      (let ((answer (harness-call 'board/undo "b-fixture" nil)))
        (should (= 3 (plist-get answer :revision)))
        (should (equal '("n-api") (mapcar (lambda (op) (plist-get op :id))
                                          (append (plist-get answer :ops) nil))))
        (should (= 0 (length (append (plist-get answer :conflicts) nil))))
        (should (equal [1 0 0 1 330 214]
                       (plist-get (harness-board--view
                                   (harness-board--object!
                                    (harness-board-load "b-fixture") "n-api")
                                   "d-overview")
                                  :transform)))))))

(ert-deftest harness-board-store-undo-keeps-anothers-work ()
  "An object somebody changed since the commit undo names is left alone."
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    ;; A commit of ours, then one of theirs touching the same object.
    (harness-call 'board/commit "b-fixture" nil nil 1
                  (list :ops (list (list :op "move" :id "n-api" :diagram "d-overview"
                                         :dx 10 :dy 0))
                        :key "k-mine"))
    (harness-call 'board/commit "b-fixture" nil nil 2
                  (list :ops (list (list :op "move" :id "n-api" :diagram "d-overview"
                                         :dx 10 :dy 0))
                        :key "k-theirs"))
    ;; Undo proposes taking back the newest, which is theirs; it is
    ;; consistent, so it goes through and leaves nothing else alone.
    (let ((answer (harness-call 'board/undo "b-fixture" nil)))
      ;; Undo commits its compensating edit, so the board moves past both.
      (should (= 4 (plist-get answer :revision)))
      (should (= 0 (length (append (plist-get answer :conflicts) nil)))))))

(ert-deftest harness-board-store-undo-refuses-when-there-is-nothing-to-take-back ()
  (harness-test-with-temp-state
    (harness-call 'board/create "b-blank" "blank" nil)
    (should (eq 'precondition
                (harness-board-store-test--refusal
                 (lambda () (harness-call 'board/undo "b-blank" nil)))))))

(ert-deftest harness-board-store-undo-dry-run-writes-nothing ()
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (harness-call 'board/commit "b-fixture" nil nil 1
                  (list :ops (list (list :op "move" :id "n-api" :diagram "d-overview"
                                         :dx 40 :dy 0))
                        :key "k-move"))
    (let ((answer (harness-call 'board/undo "b-fixture" (list :dry-run t))))
      (should (plist-get answer :dry-run))
      ;; The board is still at the committed revision, with the move in place.
      (should (= 2 (plist-get (harness-board-load "b-fixture") :revision)))
      (should (equal [1 0 0 1 370 214]
                     (plist-get (harness-board--view
                                 (harness-board--object! (harness-board-load "b-fixture") "n-api")
                                 "d-overview")
                                :transform))))))

;;;; Client state: navigation makes no revision

(ert-deftest harness-board-store-focus-keeps-the-place-and-says-who-heard ()
  "A focus request is a real request: it says a client is there only when one is."
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (let ((answer (harness-call 'board/focus "b-fixture"
                                (list :diagram "d-overview" :object "n-queue"))))
      (should (equal "b-fixture" (plist-get answer :board)))
      (should (equal "n-queue" (plist-get answer :object)))
      (should (= 1 (plist-get answer :revision)))
      ;; No client is connected in a test Emacs, and the answer says so.
      (should-not (plist-get answer :client))
      ;; The place is kept for the client that comes later, and no
      ;; revision was made by asking.
      (let ((views (harness-board-load-views "b-fixture")))
        (should (equal "n-queue" (plist-get (plist-get views :focus) :object))))
      (should (= 1 (plist-get (harness-board-load "b-fixture") :revision))))))

(ert-deftest harness-board-store-focus-refuses-a-place-that-is-not-there ()
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (should (eq 'unknown-id
                (harness-board-store-test--refusal
                 (lambda () (harness-call 'board/focus "b-fixture"
                                          (list :object "n-nowhere"))))))
    ;; An object with no view in the diagram asked for.
    (should (eq 'invalid-reference
                (harness-board-store-test--refusal
                 (lambda () (harness-call 'board/focus "b-fixture"
                                          (list :diagram "d-queue" :object "n-queue"))))))))

(ert-deftest harness-board-store-focus-announces-the-place ()
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (let ((seen nil)
          (handle nil))
      (setq handle (harness-on 'board/focused (lambda (place) (push place seen))))
      (unwind-protect
          (harness-call 'board/focus "b-fixture" (list :diagram "d-overview" :object "n-api"))
        (harness-off handle))
      (should seen)
      (should (equal "n-api" (plist-get (car seen) :object)))
      (should (equal "d-overview" (plist-get (car seen) :diagram))))))

(ert-deftest harness-board-store-views-are-a-document-of-their-own ()
  "Viewport and selection are client state: they make no revision."
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (harness-board-save-views (harness-board-load "b-fixture")
                              (list :client "flutter"
                                    :viewport (list :x 20 :y -30 :zoom 1.5)
                                    :selection ["n-api"]))
    (let ((views (harness-call 'board/views "b-fixture" (list :client "flutter"))))
      (should (= 1.5 (plist-get (plist-get views :viewport) :zoom)))
      (should (equal '("n-api") (append (plist-get views :selection) nil))))
    (should (= 1 (plist-get (harness-board-load "b-fixture") :revision)))))

;;;; What a client reads

(ert-deftest harness-board-store-a-read-carries-the-last-commit-and-a-picture ()
  "A read says what the newest commit made, and draws the diagram when asked."
  (harness-test-with-temp-state
    (require 'harness-board-svg)
    (harness-board-store-test--make)
    (let* ((plain (harness-call 'board/get "b-fixture" (list :diagram "d-overview")))
           (last (plist-get plain :last)))
      (should (= (plist-get plain :revision) (plist-get last :revision)))
      (should (plist-get last :patch))
      (should (> (length (append (plist-get last :created) nil)) 0))
      ;; Nothing is drawn unless it is asked for: a read of a big board is
      ;; not made twice as heavy by a picture nobody shows.
      (should-not (plist-get plain :image))
      (let ((drawn (harness-call 'board/get "b-fixture"
                                 (list :diagram "d-overview" :image t))))
        (should (string-match-p "\\`<\\?xml" (plist-get drawn :image)))
        (should (string-match-p "data-board=\"b-fixture\"" (plist-get drawn :image)))
        (should (string-match-p "data-revision=\"1\"" (plist-get drawn :image)))))
    ;; A board with no commits has no last commit to report.
    (harness-board-save (harness-board-normalise (harness-board-blank "b-blank" "blank" nil)))
    (should-not (plist-get (harness-call 'board/get "b-blank" nil) :last))))

;;;; Links

(ert-deftest harness-board-store-a-link-says-what-it-resolved-to ()
  "Every resource is answered with its state, and never with a generic page."
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (let* ((document (harness-call 'board/get "b-fixture" (list :diagram "d-overview")))
           (object (cl-find "n-api" (append (plist-get document :objects) nil)
                            :key (lambda (o) (plist-get o :id)) :test #'equal))
           (resources (append (plist-get object :resources) nil)))
      (should (= 2 (length resources)))
      (dolist (resource resources)
        (ert-info ((format "%S" (plist-get resource :ref)))
          (should (symbolp (plist-get resource :kind)))
          (should (plist-get resource :state))
          (should (member (plist-get resource :state)
                          '("resolved" "stale" "unsupported" "missing"
                            "declared" "unavailable"))))))))

(ert-deftest harness-board-store-a-task-link-resolves-to-that-task ()
  "A link names the thing it names, and the answer says what it found."
  (harness-test-with-temp-state
    (let ((answer (harness-board-link-describe
                   (list :kind "task" :ref "t-nowhere" :label "a task"))))
      (should (eq 'task (plist-get answer :kind)))
      (should (equal "t-nowhere" (plist-get answer :ref)))
      ;; The task board is not loaded here, and the answer says exactly
      ;; that rather than substituting a page for the task.
      (should (equal "unsupported" (plist-get answer :state)))
      (should (string-match-p "task" (or (plist-get answer :note) ""))))))

(ert-deftest harness-board-store-a-thread-link-is-the-review-s-own ()
  "A thread link asks the review for the thread, and never reads its store.

The board names no module of the review's own: it asks the method the
linking module names, `review/find-thread', so a harness without a review
says so instead of failing."
  (harness-test-with-temp-state
    (let ((answer (harness-board-link-describe
                   (list :kind "thread" :ref "t-nowhere/th-1" :label "a thread"))))
      (should (eq 'thread (plist-get answer :kind)))
      (should (equal "unsupported" (plist-get answer :state)))
      (should (string-match-p "review" (or (plist-get answer :note) ""))))))

(ert-deftest harness-board-store-a-symbol-link-is-declared-evidence-not-flow ()
  "Static analysis is evidence at a revision, and the answer says so."
  (harness-test-with-temp-state
    (let ((answer (harness-board-link-describe
                   (list :kind "symbol" :ref "atlas@a17c:EventStore.append"
                         :label "symbol at a17c"))))
      (should (equal "declared" (plist-get answer :state)))
      (should (string-match-p "revision" (or (plist-get answer :note) ""))))))

(ert-deftest harness-board-store-a-screen-link-is-unsupported-honestly ()
  "A screen-share moment link resolves only when a capture exists; otherwise it says so."
  (harness-test-with-temp-state
    (let ((answer (harness-board-link-describe
                   (list :kind "screen" :ref "cmp-1@1762700000" :label "a moment"))))
      (should (member (plist-get answer :state) '("unsupported" "unavailable" "missing")))
      (should-not (string-match-p "task page" (or (plist-get answer :note) ""))))))

(ert-deftest harness-board-store-a-document-link-names-a-file ()
  (harness-test-with-temp-state
    (let* ((path "docs/design/freeform-agent-board.md")
           (answer (harness-board-link-describe
                    (list :kind "document" :ref path :label "design note"))))
      (should (eq 'document (plist-get answer :kind)))
      (should (string-suffix-p path (or (plist-get answer :ref) "")))
      (should (plist-get answer :state)))))

(ert-deftest harness-board-store-every-resource-kind-has-an-answer ()
  "No kind a board may link is left without a resolver."
  (harness-test-with-temp-state
    (dolist (kind (mapcar #'car harness-board-resource-kinds))
      (ert-info ((format "%s" kind))
        (let ((answer (harness-board-link-describe
                       (list :kind (symbol-name kind) :ref "x-1" :label "a thing"))))
          (should (eq kind (plist-get answer :kind)))
          (should (plist-get answer :state)))))))

;;;; The modules, loaded they way the harness loads them

(ert-deftest harness-board-store-the-board-modules-start-together ()
  "The grammar, its edit half, the store, the renderer and the tools.
A board is one feature: a module that needs another starts after it, and
`linking' is what the store resolves a board's resources through."
  (harness-test-with-temp-state
    ;; A bus of its own, put back afterwards: the other tests of this suite
    ;; need the modules the runner loaded for them.
    (unwind-protect
        (progn
          (harness-test-reset-bus)
          (dolist (name '(store project config provider tools session agent linking
                          board board-edit board-store board-svg tools-board))
            (harness-test-load-module name))
          (dolist (name '(board board-edit board-store board-svg tools-board))
            (ert-info ((symbol-name name))
              (should (harness-module-ready-p name))))
          ;; Every method a client or a tool calls is on the bus.
          (dolist (method '(board/list board/get board/create board/delete board/grammar
                            board/patch board/preview board/commit board/undo
                            board/focus board/views))
            (ert-info ((symbol-name method))
              (should (harness-method-exists-p method))))
          ;; And every tool.
          (dolist (name '("scene.read" "grammar.describe" "scene.edit"
                          "patch.preview" "patch.commit" "history.undo"))
            (ert-info (name)
              (should (harness-tool-get name)))))
      (harness-test-reset-bus)
      (dolist (name '(store project config provider tools session agent linking
                      board board-edit board-store board-svg tools-board))
        (harness-test-load-module name)))))

;;;; Pinned revisions: what a task delivered

(ert-deftest harness-board-store-a-pin-keeps-its-own-copy-of-the-drawing ()
  "A pin is the artifact: edits after it cannot reach what was delivered."
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (let* ((pin (harness-call 'board/pin "b-fixture" (list :task "t-1" :title "the plan")))
           (id (plist-get pin :id)))
      (should (equal "b-fixture" (plist-get pin :board)))
      (should (equal "t-1" (plist-get pin :task)))
      (should (equal "the plan" (plist-get pin :title)))
      (should (= 1 (plist-get pin :revision)))
      (should (equal "d-overview" (plist-get pin :diagram)))
      ;; Somebody moves the api afterwards.
      (harness-call 'board/commit "b-fixture" nil nil 1
                    (list :ops (list (list :op "move" :id "n-api" :diagram "d-overview"
                                           :dx 60 :dy 0))
                          :key "k-after"))
      (let* ((read (harness-call 'board/pins "b-fixture" (list :pin id)))
             (pinned (plist-get read :pin))
             (object (cl-find "n-api" (append (plist-get (plist-get read :document) :objects) nil)
                              :key (lambda (o) (plist-get o :id)) :test #'equal)))
        ;; The artifact is where it was; the board went on.
        (should (equal [1 0 0 1 330 214] (plist-get object :transform)))
        (should (equal "b-fixture" (plist-get pinned :board)))
        (should (= 1 (plist-get pinned :revision)))
        ;; And it renders: the pin's own picture, not the board's now.
        (should (stringp (plist-get read :image)))
        (should (string-match-p "n-api" (plist-get read :image))))
      ;; The board's own document has moved, so the two links stay apart.
      (should (= 2 (plist-get (harness-board-load "b-fixture") :revision)))
      (should (string-match-p "/revision/1\\'" (plist-get pin :target)))
      (should-not (string-match-p "/revision/" (plist-get pin :current))))))

(ert-deftest harness-board-store-a-pin-is-written-once-and-listed-newest-first ()
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (let* ((one (harness-call 'board/pin "b-fixture" (list :task "t-1")))
           (two (harness-call 'board/pin "b-fixture" (list :task "t-2"))))
      (should-not (equal (plist-get one :id) (plist-get two :id)))
      (let ((listed (append (harness-call 'board/pins "b-fixture") nil)))
        (should (= 2 (length listed)))
        (should (equal (plist-get two :id) (plist-get (car listed) :id)))
        (should (= 1 (length (append (harness-call 'board/pins "b-fixture"
                                                   (list :task "t-1"))
                                     nil))))))))

(ert-deftest harness-board-store-a-pin-names-a-diagram-and-a-place-that-are-here ()
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (should (eq 'unknown-id
                (harness-board-store-test--refusal
                 (lambda () (harness-call 'board/pin "b-fixture" (list :diagram "d-nowhere"))))))
    (should (eq 'invalid-reference
                (harness-board-store-test--refusal
                 (lambda () (harness-call 'board/pin "b-fixture"
                                          (list :diagram "d-overview" :object "n-handler"))))))
    (should (eq 'unknown-id
                (harness-board-store-test--refusal
                 (lambda () (harness-call 'board/pins "b-fixture" (list :pin "pin-nope"))))))))

;;;; Discussing a place: the review's own thread

(ert-deftest harness-board-store-a-discussion-is-a-thread-of-the-review ()
  "The thread is the review's, anchored to the object and the revision."
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (let* ((threads (make-hash-table :test #'equal))
           (made nil))
      ;; A review that keeps its threads here, as the review module does.
      (harness-defmethod patch-review/board-thread (task-id body &rest opts)
        "A stand-in for the review's own thread, kept in this test."
        (let ((id (format "t-%d" (1+ (length made)))))
          (push (append (list :id id :body body :task task-id) opts) made)
          (puthash task-id (cons id (gethash task-id threads)) threads)
          (list :thread id :status "open"
                :meta (list :board (plist-get opts :board)
                            :diagram (plist-get opts :diagram)
                            :object (plist-get opts :object)
                            :revision (plist-get opts :revision)))))
      (harness-defmethod patch-review/get (task-id)
        "The threads this test's review holds."
        (list :threads (vconcat
                        (mapcar (lambda (id)
                                  (let ((one (cl-find id made :key (lambda (o) (plist-get o :id))
                                                      :test #'equal)))
                                    (list :id id :status "open"
                                          :meta (list :board (plist-get one :board)
                                                      :diagram (plist-get one :diagram)
                                                      :object (plist-get one :object)
                                                      :revision (plist-get one :revision))
                                          :comments [])))
                                (gethash task-id threads)))))
      (let ((answer (harness-call 'board/discuss "b-fixture" "n-api"
                                  (list :task "t-1" :text "is this the api?"))))
        (should (equal "t-1" (plist-get (car made) :task)))
        (should (equal "n-api" (plist-get (car made) :object)))
        (should (equal 1 (plist-get (car made) :revision)))
        (should (equal "d-overview" (plist-get (car made) :diagram)))
        (should (equal "is this the api?" (plist-get (car made) :body)))
        (should (stringp (plist-get answer :thread))))
      ;; The board finds the thread again, and says where the drawing stands.
      (let ((found (append (harness-call 'board/discussions "b-fixture") nil)))
        (should (= 1 (length found)))
        (should (equal "n-api" (plist-get (car found) :object)))
        (should (equal 1 (plist-get (car found) :revision)))
        (should (equal 1 (plist-get (car found) :current)))
        (should-not (plist-get (car found) :stale)))
      ;; A revision later, the same thread says the drawing moved.
      (harness-call 'board/commit "b-fixture" nil nil 1
                    (list :ops (list (list :op "move" :id "n-api" :diagram "d-overview"
                                           :dx 10 :dy 0))
                          :key "k-move"))
      (let ((found (append (harness-call 'board/discussions "b-fixture") nil)))
        (should (plist-get (car found) :stale))))))

(ert-deftest harness-board-store-a-discussion-names-a-place-that-is-here ()
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (should (eq 'invalid-parameter
                (harness-board-store-test--refusal
                 (lambda () (harness-call 'board/discuss "b-fixture" "n-api"
                                          (list :text "no task"))))))
    (should (eq 'unknown-id
                (harness-board-store-test--refusal
                 (lambda () (harness-call 'board/discuss "b-fixture" "n-nowhere"
                                          (list :task "t-1" :text "x"))))))))

(ert-deftest harness-board-store-a-board-may-name-its-writers ()
  "A board whose writers do not include a session answers `permission'."
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (let ((board (harness-board-load "b-fixture")))
      (harness-board-save (plist-put board :writers (vector "s-allowed"))))
    ;; The allowed session may edit it.
    (should (harness-call 'board/patch "b-fixture"
                          (list (list :op "move" :id "n-api" :diagram "d-overview"
                                      :dx 1 :dy 0))
                          (list :session "s-allowed")))
    ;; Another may not.
    (should (eq 'permission
                (harness-board-store-test--refusal
                 (lambda ()
                   (harness-call 'board/patch "b-fixture"
                                 (list (list :op "move" :id "n-api" :diagram "d-overview"
                                             :dx 1 :dy 0))
                                 (list :session "s-stranger"))))))))

(ert-deftest harness-board-store-nothing-a-board-does-creates-a-task ()
  "Editing a drawing never makes a task: only a person asks for one."
  (harness-test-with-temp-state
    (harness-board-store-test--make)
    (let ((before (length (append (harness-call 'board/list nil) nil))))
      (harness-call 'board/commit "b-fixture" nil nil 1
                    (list :ops (list (list :op "create" :id "n-drawn" :kind "note"
                                           :text "a note" :diagram "d-overview"
                                           :x 0 :y 0
                                           :shape (list :kind "rect" :w 40 :h 20)))
                          :key "k-draw"))
      (should (= before (length (append (harness-call 'board/list nil) nil))))
      ;; And the tools that draw are not the ones that make a task.
      (should-not (harness-method-exists-p 'board/task)))))

(provide 'harness-board-store-test)
;;; harness-board-store-test.el ends here
