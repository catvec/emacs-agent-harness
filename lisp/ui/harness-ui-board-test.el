;;; harness-ui-board-test.el --- Tests for the board pages  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The board pages (harness-ui-board.el): what they draw, word for word
;; -- their headings, labels, states, buttons and tooltips -- and what
;; their commands, keys and event hook do.  The pages talk ACP only, so
;; the answers are put into the buffer the way an answer would arrive:
;; a document read from a real board, made through the board's own
;; grammar in `test/fixtures/harness-board-fixture.el'.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)

(defvar harness-acp--server-enabled nil)
(defvar harness-ui-board--boards)
(defvar harness-ui-board--document)
(defvar harness-ui-board--id)
(defvar harness-ui-board--diagram)
(defvar harness-ui-board--project)
(defvar harness-ui-board--all)
(defvar harness-ui-board--loaded)
(defvar harness-ui-board--error)
(declare-function harness-ui-board--list-buffer "harness-ui-board" ())
(declare-function harness-ui-board--board-buffer "harness-ui-board" (id))
(declare-function harness-ui-board--render "harness-ui-board" ())
(declare-function harness-ui-board--header "harness-ui-board" ())
(declare-function harness-ui-boards--render "harness-ui-board" ())
(declare-function harness-ui-boards--header "harness-ui-board" ())
(declare-function harness-ui-boards-refresh "harness-ui-board" ())
(declare-function harness-ui-board-refresh "harness-ui-board" ())
(declare-function harness-ui-board--on-event "harness-ui-board" (event args))
(declare-function harness-ui-board--on-connect "harness-ui-board" ())
(declare-function harness-ui-board-links "harness-ui-board" (object &optional board))
(declare-function harness-ui-board-focus "harness-ui-board" (object &optional board))
(declare-function harness-ui-board-open "harness-ui-board" (id &optional diagram object))
(declare-function harness-ui-board-snapshot "harness-ui-board" ())
(declare-function harness-ui-board--object-at-point "harness-ui-board" ())
(declare-function harness-ui-board--line-of "harness-ui-board" (id))
(declare-function harness-ui-board--follow "harness-ui-board" (resource))
(declare-function harness-board-fixture-board "harness-board-fixture" (&optional ops))

(defconst harness-ui-board-test-modules
  '(store project config provider provider-demo tools session agent tools-agent perms readonly mcp acp
    board board-edit board-store ui ui-linking ui-board)
  "The modules every test loads.")

(defvar harness-ui-board-test-document nil
  "The document the page is drawn from, made once by the fixture.")

(defmacro harness-ui-board-test-with (&rest body)
  "Load the UI, the linking and the board pages, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (setq harness-acp--server-enabled nil)
     (dolist (m harness-ui-board-test-modules)
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (let ((default-directory (harness-test-temp-dir)))
       (load (expand-file-name "test/fixtures/harness-board-fixture.el"
                      harness-test-root))
       (setq harness-ui-board-test-document
             (harness-board-fixture-board))
       (unwind-protect
           (progn ,@body)
         (dolist (buffer (list (harness-ui-board--list-buffer)
                               (harness-ui-board--board-buffer "b-fixture")))
           (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(defun harness-ui-board-test-draw (&rest state)
  "Draw the board page with STATE, a plist of the buffer's answers, and return its text.
The text has no properties, so it is the words a person reads."
  (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
    (unless (derived-mode-p 'harness-ui-board-mode)
      (harness-ui-board-mode))
    (when (plist-member state :document)
      (setq harness-ui-board--document (plist-get state :document)))
    (when (plist-member state :id)
      (setq harness-ui-board--id (plist-get state :id)))
    (when (plist-member state :diagram)
      (setq harness-ui-board--diagram (plist-get state :diagram)))
    (when (plist-member state :error)
      (setq harness-ui-board--error (plist-get state :error)))
    (when (plist-member state :pins)
      (setq harness-ui-board--pins (plist-get state :pins)
            harness-ui-board--pins-loaded t))
    (harness-ui-board--render)
    (substring-no-properties (buffer-string))))

(defun harness-ui-board-test-draw-list (&rest state)
  "Draw the list of boards with STATE, and return its text without properties."
  (with-current-buffer (harness-ui-board--list-buffer)
    (unless (derived-mode-p 'harness-ui-boards-mode)
      (harness-ui-boards-mode))
    (when (plist-member state :boards)
      (setq harness-ui-board--boards (plist-get state :boards)
            harness-ui-board--loaded t))
    (when (plist-member state :loaded)
      (setq harness-ui-board--loaded (plist-get state :loaded)))
    (when (plist-member state :all)
      (setq harness-ui-board--all (plist-get state :all)))
    (when (plist-member state :error)
      (setq harness-ui-board--error (plist-get state :error)))
    (harness-ui-boards--render)
    (substring-no-properties (buffer-string))))

(defun harness-ui-board-test-header (&optional list)
  "Return the page's header line as the words a person reads.
LIST draws the list's header rather than the board's."
  (with-current-buffer (if list
                           (harness-ui-board--list-buffer)
                         (harness-ui-board--board-buffer "b-fixture"))
    (mapconcat (lambda (part) (substring-no-properties (format "%s" part)))
               (if list (harness-ui-boards--header) (harness-ui-board--header))
               "")))

(defun harness-ui-board-test-help (label &optional list)
  "Return the tooltip of the button LABEL on the page, or nil.
LIST looks in the list of boards.  LABEL is matched as it is written."
  (with-current-buffer (if list
                           (harness-ui-board--list-buffer)
                         (harness-ui-board--board-buffer "b-fixture"))
    (let ((case-fold-search nil))
      (goto-char (point-min))
      (when (search-forward label nil t)
        (get-text-property (match-beginning 0) 'help-echo)))))

(defun harness-ui-board-test-calls (function &rest args)
  "Call FUNCTION with ARGS, and return the requests it made, oldest first.
Each request is (METHOD PARAMS).  Answers are not delivered: what the
command asks for is what is looked at."
  (let ((calls nil))
    (cl-letf (((symbol-function 'harness-ui-connected-p) (lambda () t))
              ((symbol-function 'harness-ui-call)
               (lambda (method params &optional _callback _on-error)
                 (push (list method params) calls)))
              ((symbol-function 'harness-ui-display-view) (lambda (&rest _) nil)))
      (apply function args))
    (nreverse calls)))

;;;; The page, word for word

(ert-deftest harness-ui-board-a-page-shows-the-drawing-and-its-objects ()
  "The board page shows the snapshot, the diagram, the commit and every object."
  (harness-ui-board-test-with
    (let ((text (harness-ui-board-test-draw :document harness-ui-board-test-document
                                            :id "b-fixture" :diagram "d-overview")))
      (dolist (heading '("Snapshot" "Diagram" "Last commit" "Objects" "Connections" "Keys"))
        (should (string-match-p (concat "\n " heading " ─") text)))
      ;; The board's own words, from the document: the name, the theme and
      ;; the revision, and the labels of the page beside them.
      (should (string-match-p "atlas / fieldnotes" text))
      (should (string-match-p "b-fixture · electric-commons · rev 1" text))
      (should (string-match-p "Selection" text))
      (should (string-match-p "Diagrams" text))
      (should (string-match-p "Viewport" text))
      ;; Every object of the drawing has a row with its kind, its name and
      ;; what it says.
      (dolist (words '("frame" "the system" "component" "worker pool" "executes jobs"
                       "questions" "path" "store"))
        (should (string-match-p (regexp-quote words) text)))
      ;; A connector is a row of its own, with both ends and its label.
      (should (string-match-p "flow" text))
      (should (string-match-p "n-api.right → n-workers.left" text))
      (should (string-match-p "jobs" text)))))

(ert-deftest harness-ui-board-a-page-shows-a-links-state ()
  "A link the page shows says what it resolved to, in its own word."
  (harness-ui-board-test-with
    (let* ((document (plist-put (copy-sequence harness-ui-board-test-document) :objects
                                (vector
                                 (list :id "n-api" :kind "component" :name "api"
                                       :text "accepts jobs" :role "declared"
                                       :diagram "d-overview"
                                       :resources (vector
                                                   (list :kind "task" :ref "t-8f2"
                                                         :state "resolved" :note "review")
                                                   (list :kind "message" :ref "s-1/n-9"
                                                         :state "stale")
                                                   (list :kind "screen" :ref "c-1/12:04"
                                                         :state "unsupported"))))))
           (text (harness-ui-board-test-draw :document document :id "b-fixture")))
      (should (string-match-p "     task t-8f2 · resolved · review" text))
      (should (string-match-p "     message s-1/n-9 · stale" text))
      (should (string-match-p "     screen c-1/12:04 · unsupported" text)))))

(ert-deftest harness-ui-board-a-task-marker-is-the-task-s-own-words ()
  "A task marker shows the source's status, in its own word, and nothing invented."
  (harness-ui-board-test-with
    (let* ((document (plist-put (copy-sequence harness-ui-board-test-document) :objects
                                (vector
                                 (list :id "n-api" :kind "component" :name "api"
                                       :text "accepts jobs" :role "declared"
                                       :diagram "d-overview"
                                       :source-status (list :status "active"
                                                            :label "working · t-8f2")))))
           (text (harness-ui-board-test-draw :document document :id "b-fixture")))
      (should (string-match-p "   task working · t-8f2" text)))))

(ert-deftest harness-ui-board-a-locked-and-a-mirrored-object-say-so ()
  "An object that is locked, or whose view is reflected, is marked in words."
  (harness-ui-board-test-with
    (let* ((document (plist-put (copy-sequence harness-ui-board-test-document) :objects
                                (vector
                                 (list :id "n-api" :kind "component" :name "api"
                                       :text "accepts jobs" :role "declared"
                                       :diagram "d-overview" :locked t :mirrored t))))
           (text (harness-ui-board-test-draw :document document :id "b-fixture")))
      (should (string-match-p "declared locked mirrored" text)))))

(ert-deftest harness-ui-board-a-page-says-what-it-is-waiting-for ()
  "An empty page, and one that failed, say so rather than looking empty."
  (harness-ui-board-test-with
    (should (string-match-p "…" (harness-ui-board-test-draw :document nil :id "b-fixture")))
    (let ((text (harness-ui-board-test-draw :document nil :id "b-fixture"
                                            :error "unknown-id: no board b-fixture")))
      (should (string-match-p "unknown-id: no board b-fixture" text))
      (should (string-match-p "unknown-id: no board b-fixture"
                              (harness-ui-board-test-header)))
      ;; The page offers to load the board again, in the body and the header.
      (should (string-match-p (regexp-quote "unknown-id: no board b-fixture  [Retry]") text))
      (should (string-match-p (regexp-quote "unknown-id: no board b-fixture [Retry]")
                              (harness-ui-board-test-header)))
      (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
        (should (equal "Load the board again"
                       (get-text-property (string-match (regexp-quote "[Retry]") (buffer-string))
                                          'help-echo (buffer-string))))))))

(ert-deftest harness-ui-boards-a-failure-offers-retry ()
  "The list of boards that could not be loaded offers to load it again."
  (harness-ui-board-test-with
    (let ((text (harness-ui-board-test-draw-list :boards nil :loaded t :error "no connection")))
      (should (string-match-p (regexp-quote "no connection  [Retry]") text)))
    (with-current-buffer (harness-ui-board--list-buffer)
      (should (equal "Load the boards again"
                     (get-text-property (string-match (regexp-quote "[Retry]") (buffer-string))
                                        'help-echo (buffer-string)))))))

(ert-deftest harness-ui-board-a-snapshot-without-an-svg-display-says-which ()
  "An Emacs that cannot draw the snapshot says so in a phrase, not a sentence."
  (harness-ui-board-test-with
    (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) nil)))
      (let ((text (harness-ui-board-test-draw
                   :document (plist-put (copy-sequence harness-ui-board-test-document)
                                        :image "<svg/>")
                   :id "b-fixture" :diagram "d-overview")))
        (should (string-match-p "no snapshot · no SVG display" text))))))

(ert-deftest harness-ui-board-a-diagram-with-nothing-in-it-says-so ()
  "A diagram with no object, no connection and no selection names each absence."
  (harness-ui-board-test-with
    (let* ((document (list :id "b-empty" :name "empty" :theme "open-labels" :revision 1
                           :diagrams (vector (list :id "d-one" :name "one" :parent nil
                                                   :x 0 :y 0 :zoom 1 :selection (vector)))
                           :objects (vector) :relationships (vector)))
           (text (harness-ui-board-test-draw :document document :id "b-empty"
                                             :diagram "d-one")))
      (should (string-match-p "no object" text))
      (should (string-match-p "no connection" text))
      (should (string-match-p "no selection" text))
      (should (string-match-p "no commit" text)))))

(ert-deftest harness-ui-board-the-buttons-and-their-tooltips ()
  "Each button of a page says what it does, in the same words the key has."
  (harness-ui-board-test-with
    (let ((text (harness-ui-board-test-draw :document harness-ui-board-test-document
                                            :id "b-fixture" :diagram "d-overview")))
      (dolist (label '("[Links]" "[Diagram]" "[Flutter]" "[Refresh]" "[Snapshot]"
                       "[Board list]"))
        (should (string-match-p (regexp-quote label) text))))
    (should (equal "links of the object at point (RET)"
                   (harness-ui-board-test-help "[Links]")))
    (should (equal "the diagram at point (d)"
                   (harness-ui-board-test-help "[Diagram]")))
    (should (equal "the object at point in the Flutter client (f)"
                   (harness-ui-board-test-help "[Flutter]")))
    (should (equal "board refresh (g)" (harness-ui-board-test-help "[Refresh]")))
    (should (equal "the snapshot of the diagram at point (s)"
                   (harness-ui-board-test-help "[Snapshot]")))
    (should (equal "board list (l)" (harness-ui-board-test-help "[Board list]")))))

;;;; The list of boards

(ert-deftest harness-ui-boards-a-list-shows-each-board-and-where-it-is ()
  "The list names each board, its project, its theme and its revision."
  (harness-ui-board-test-with
    (let ((text (harness-ui-board-test-draw-list
                 :boards (vector (list :id "b-fieldnotes" :name "atlas / fieldnotes"
                                       :project "/home/noah/src/atlas"
                                       :theme "electric-commons" :revision 12
                                       :updated 1762700900.0 :diagrams 2 :objects 49
                                       :markers 1)
                                 (list :id "b-other" :name "notes" :project nil
                                       :theme "night-commons" :revision 3
                                       :updated 1762700000.0 :diagrams 1 :objects 4
                                       :markers 0)))))
      (should (string-match-p "\n Boards" text))
      (should (string-match-p "2 boards" (harness-ui-board-test-header t)))
      (dolist (words '("atlas / fieldnotes" "/home/noah/src/atlas" "electric-commons"
                       "rev 12" "notes" "night-commons" "rev 3"))
        (should (string-match-p (regexp-quote words) text)))
      (should (string-match-p "\\[Open\\]" text))
      (should (string-match-p "\\[Flutter\\]" text)))))

(ert-deftest harness-ui-boards-a-list-says-when-there-is-no-board ()
  "An empty list, and one still being read, say which they are."
  (harness-ui-board-test-with
    (should (string-match-p "no board" (harness-ui-board-test-draw-list :boards nil)))
    (should (string-match-p "no board" (harness-ui-board-test-header t)))
    (should (string-match-p "…" (harness-ui-board-test-draw-list :boards nil :loaded nil)))))

(ert-deftest harness-ui-boards-the-list-s-buttons-and-their-tooltips ()
  "The list's buttons say what they do, in the words their keys have."
  (harness-ui-board-test-with
    (let ((text (harness-ui-board-test-draw-list :boards nil)))
      (should (string-match-p "\\[Refresh\\]" text))
      (should (string-match-p "\\[Every project\\]" text)))
    (should (equal "board list refresh (g)"
                   (harness-ui-board-test-help "[Refresh]" t)))
    (should (equal "boards of every project (a)"
                   (harness-ui-board-test-help "[Every project]" t)))))

(ert-deftest harness-ui-boards-a-list-reads-the-project-s-boards ()
  "The list asks for the project's boards, or for every project's."
  (harness-ui-board-test-with
    (with-current-buffer (harness-ui-board--list-buffer)
      (harness-ui-boards-mode)
      (setq harness-ui-board--project "/home/noah/src/atlas"
            harness-ui-board--all nil))
    (let ((calls (harness-ui-board-test-calls
                  (lambda ()
                    (with-current-buffer (harness-ui-board--list-buffer)
                      (harness-ui-boards-refresh))))))
      (should (equal (car calls)
                     '("_harness/board/list" (:opts (:project "/home/noah/src/atlas"))))))
    (with-current-buffer (harness-ui-board--list-buffer)
      (setq harness-ui-board--all t))
    (let ((calls (harness-ui-board-test-calls
                  (lambda ()
                    (with-current-buffer (harness-ui-board--list-buffer)
                      (harness-ui-boards-refresh))))))
      (should (equal (car calls) '("_harness/board/list" (:opts (:all t))))))))

(ert-deftest harness-ui-boards-with-no-connection-says-so-and-asks-nothing ()
  "With no harness to ask, the list says so in words and sends no request."
  (harness-ui-board-test-with
    (with-current-buffer (harness-ui-board--list-buffer)
      (harness-ui-boards-mode))
    (let ((sent nil) (said nil))
      (cl-letf (((symbol-function 'harness-ui-connected-p) (lambda () nil))
                ((symbol-function 'harness-ui-call) (lambda (&rest _) (setq sent t)))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq said (apply #'format format-string args)))))
        (with-current-buffer (harness-ui-board--list-buffer)
          (harness-ui-boards-refresh)))
      (should-not sent)
      (should (equal "Harness: no connection" said))
      (should (string-match-p "no connection"
                              (with-current-buffer (harness-ui-board--list-buffer)
                                (substring-no-properties (buffer-string))))))))

;;;; Opening a board, and what a request asks for

(ert-deftest harness-ui-board-open-asks-for-the-board-and-its-diagram ()
  "Opening a board asks for it, at the diagram and object named."
  (harness-ui-board-test-with
    (let ((calls (harness-ui-board-test-calls #'harness-ui-board-open "b-fixture")))
      (should (equal (car calls)
                     '("_harness/board/get" (:id "b-fixture")))))
    (let ((calls (harness-ui-board-test-calls #'harness-ui-board-open
                                              "b-fixture" "d-queue" "n-handler")))
      (should (equal (car calls)
                     '("_harness/board/get"
                       (:id "b-fixture" :opts (:diagram "d-queue" :image t))))))
    (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
      (should (equal harness-ui-board--id "b-fixture"))
      (should (equal harness-ui-board--diagram "d-queue")))))

(ert-deftest harness-ui-board-a-page-reads-the-diagram-it-shows ()
  "Refreshing a page reads the board, at the diagram the page is on."
  (harness-ui-board-test-with
    (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
      (harness-ui-board-mode)
      (setq harness-ui-board--id "b-fixture" harness-ui-board--diagram "d-overview"))
    (let ((calls (harness-ui-board-test-calls
                  (lambda ()
                    (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
                      (harness-ui-board-refresh))))))
      (should (equal (car calls)
                     '("_harness/board/get"
                       (:id "b-fixture" :opts (:diagram "d-overview" :image t))))))))

(ert-deftest harness-ui-board-an-answer-draws-the-page ()
  "The answer to a read is what the page draws: it is not a second model."
  (harness-ui-board-test-with
    (let ((document harness-ui-board-test-document))
      (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
        (harness-ui-board-mode)
        (setq harness-ui-board--id "b-fixture")
        (cl-letf (((symbol-function 'harness-ui-connected-p) (lambda () t))
                  ((symbol-function 'harness-ui-call)
                   (lambda (_method _params callback &optional _on-error)
                     (funcall callback document))))
          (harness-ui-board-refresh))
        (should (equal harness-ui-board--diagram "d-overview"))
        (let ((text (substring-no-properties (buffer-string))))
          (should (string-match-p "atlas / fieldnotes" text))
          (should (string-match-p "worker pool" text)))))))

(ert-deftest harness-ui-board-a-failed-read-says-what-failed ()
  "A read that failed puts the harness's own words on the page and the echo area."
  (harness-ui-board-test-with
    (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
      (harness-ui-board-mode)
      (setq harness-ui-board--id "b-fixture"))
    (let ((said nil))
      (cl-letf (((symbol-function 'harness-ui-connected-p) (lambda () t))
                ((symbol-function 'harness-ui-call)
                 (lambda (_method _params _callback on-error)
                   ;; The harness answers a failed read as an ACP error,
                   ;; whose message is what the person is told.
                   (funcall on-error (list 'acp-error -32000 "no board b-fixture" nil))))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq said (apply #'format format-string args)))))
        (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
          (harness-ui-board-refresh)))
      (should (equal "Harness: board read: no board b-fixture" said))
      (should (equal "no board b-fixture"
                     (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
                       harness-ui-board--error))))))

;;;; At point

(ert-deftest harness-ui-board-point-on-a-row-is-the-object ()
  "Point on an object's row is that object; point elsewhere is none."
  (harness-ui-board-test-with
    (harness-ui-board-test-draw :document harness-ui-board-test-document
                                :id "b-fixture" :diagram "d-overview")
    (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
      (goto-char (point-min))
      (should (search-forward "worker pool" nil t))
      (let ((object (harness-ui-board--object-at-point)))
        (should (equal (plist-get object :id) "n-workers"))
        (should (equal (plist-get object :name) "worker pool")))
      (goto-char (point-min))
      (should-not (harness-ui-board--object-at-point)))))

(ert-deftest harness-ui-board-an-object-s-links-are-offered-by-name ()
  "The links of an object at point are offered, each with its state."
  (harness-ui-board-test-with
    (harness-ui-board-test-draw :document harness-ui-board-test-document
                                :id "b-fixture" :diagram "d-overview")
    (let ((offered nil) (followed nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq offered collection)
                   (car collection)))
                ((symbol-function 'harness-ui-board--follow)
                 (lambda (resource) (setq followed resource))))
        (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
          (goto-char (point-min))
          (search-forward "api" nil t)
          (harness-ui-board-links (harness-ui-board--object-at-point))))
      (should offered)
      (should (cl-every (lambda (line) (string-match-p " · " line)) offered))
      (should (eq (plist-get followed :kind) 'task)))))

(ert-deftest harness-ui-board-no-link-at-point-says-so ()
  "An object with no link, and a place with no object, say there is none."
  (harness-ui-board-test-with
    (let ((said nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq said (apply #'format format-string args)))))
        (harness-ui-board-links nil)
        (should (equal "Harness: no link at point" said))))))

(ert-deftest harness-ui-board-a-link-opens-what-it-names ()
  "A link is followed to the precise thing it names, not to a task's front page."
  (harness-ui-board-test-with
    (let ((followed nil) (board-opened nil) (browsed nil))
      (cl-letf (((symbol-function 'harness-links-p) (lambda (_) t))
                ((symbol-function 'harness-links-parse)
                 (lambda (target)
                   (if (string-match-p "\\`harness:board/" target)
                       (list :kind 'board :board "b-fixture" :board-diagram "d-queue"
                             :board-object "n-handler")
                     (list :kind 'message))))
                ((symbol-function 'harness-ui-linking-follow)
                 (lambda (target) (setq followed target)))
                ((symbol-function 'harness-ui-board-open)
                 (lambda (&rest args) (setq board-opened args)))
                ((symbol-function 'browse-url) (lambda (url) (setq browsed url))))
        (harness-ui-board--follow (list :kind "message" :target "harness:message/abc"
                                        :state "resolved"))
        (should (equal followed "harness:message/abc"))
        (harness-ui-board--follow
         (list :kind "diagram"
               :target "harness:board/b-fixture/diagram/d-queue/object/n-handler"
               :state "resolved"))
        (should (equal board-opened '("b-fixture" "d-queue" "n-handler")))
        (harness-ui-board--follow (list :kind "document" :target "https://example.test/doc"
                                        :state "resolved"))
        (should (equal browsed "https://example.test/doc"))))))

(ert-deftest harness-ui-board-a-link-that-cannot-open-says-why ()
  "A stale or unsupported link is reported in its own words, not opened."
  (harness-ui-board-test-with
    (let ((said nil) (opened nil))
      (cl-letf (((symbol-function 'harness-ui-linking-follow) (lambda (&rest _) (setq opened t)))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq said (apply #'format format-string args)))))
        (harness-ui-board--follow (list :kind "screen" :label "screen · 12:04"
                                        :target nil :state "unsupported")))
      (should-not opened)
      (should (equal "Harness: screen · 12:04 · unsupported" said)))))

;;;; Opening the same place in Flutter

(ert-deftest harness-ui-board-focus-asks-the-client-for-the-place ()
  "Focus asks a client to show the object at its diagram, in one request."
  (harness-ui-board-test-with
    (harness-ui-board-test-draw :document harness-ui-board-test-document
                                :id "b-fixture" :diagram "d-overview")
    (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
      (goto-char (point-min))
      (search-forward "worker pool" nil t)
      (let ((calls (harness-ui-board-test-calls
                    (lambda () (harness-ui-board-focus (harness-ui-board--object-at-point))))))
        (should (equal (car calls)
                       '("_harness/board/focus"
                         (:id "b-fixture"
                          :opts (:diagram "d-overview" :object "n-workers")))))))))

(ert-deftest harness-ui-board-focus-with-no-connection-says-so ()
  "With no client connected, focus says so and asks nothing."
  (harness-ui-board-test-with
    (let ((sent nil) (said nil))
      (cl-letf (((symbol-function 'harness-ui-connected-p) (lambda () nil))
                ((symbol-function 'harness-ui-call) (lambda (&rest _) (setq sent t)))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq said (apply #'format format-string args)))))
        (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
          (harness-ui-board-focus nil "b-fixture")))
      (should-not sent)
      (should (equal "Harness: no connection" said)))))

(ert-deftest harness-ui-board-focus-with-no-board-says-so ()
  "With no board to name, focus says so and asks nothing."
  (harness-ui-board-test-with
    (let ((sent nil) (said nil))
      (cl-letf (((symbol-function 'harness-ui-connected-p) (lambda () t))
                ((symbol-function 'harness-ui-call) (lambda (&rest _) (setq sent t)))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq said (apply #'format format-string args)))))
        (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
          (setq harness-ui-board--id nil)
          (harness-ui-board-focus nil nil)))
      (should-not sent)
      (should (equal "Harness: no board at point" said)))))

(ert-deftest harness-ui-board-a-snapshot-is-the-document-s-own-rendering ()
  "The snapshot opens the SVG the read answered, and says so when there is none."
  (harness-ui-board-test-with
    (let ((opened nil) (said nil))
      (cl-letf (((symbol-function 'find-file-other-window) (lambda (file) (setq opened file)))
                ((symbol-function 'harness-ui-image-open) nil)
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq said (apply #'format format-string args)))))
        (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
          (setq harness-ui-board--document (list :image "<svg/>"))
          (harness-ui-board-snapshot))
        (should opened)
        (should (string-suffix-p ".svg" opened))
        (setq said nil)
        (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
          (setq harness-ui-board--document (list :image nil))
          (harness-ui-board-snapshot))
        (should (equal "Harness: no snapshot" said))))))

;;;; The breadcrumb, and back

(ert-deftest harness-ui-board-the-breadcrumb-walks-to-the-diagram ()
  "A diagram's line is its parents, root first, ending at the diagram itself."
  (harness-ui-board-test-with
    (let ((document (list :diagrams (vector
                                     (list :id "d-overview" :name "overview" :parent nil)
                                     (list :id "d-queue" :name "queue" :parent "d-overview")
                                     (list :id "d-retry" :name "retry" :parent "d-queue")))))
      (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
        (setq harness-ui-board--document document)
        (should (equal (mapcar (lambda (d) (plist-get d :id))
                               (harness-ui-board--line-of "d-retry"))
                       '("d-overview" "d-queue" "d-retry")))
        (should (equal (mapcar (lambda (d) (plist-get d :id))
                               (harness-ui-board--line-of "d-overview"))
                       '("d-overview")))
        ;; A parent that is not there ends the walk; a cycle ends it too.
        (should (equal (harness-ui-board--line-of "d-gone") nil))
        (setq harness-ui-board--document
              (list :diagrams (vector (list :id "a" :name "a" :parent "b")
                                      (list :id "b" :name "b" :parent "a"))))
        (should (= 2 (length (harness-ui-board--line-of "a"))))))))

(ert-deftest harness-ui-board-the-breadcrumb-is-drawn-with-its-diagram ()
  "The page draws the walked line, with the diagram it shows named last."
  (harness-ui-board-test-with
    (let* ((document (plist-put (copy-sequence harness-ui-board-test-document)
                                :diagrams
                                (vector (list :id "d-overview" :name "overview" :parent nil
                                              :viewport (list :x 0 :y 0 :zoom 1)
                                              :selection (vector))
                                        (list :id "d-queue" :name "queue" :parent "d-overview"
                                              :viewport (list :x 40 :y 12 :zoom 1.5)
                                              :selection (vector "n-handler")))))
           (text (harness-ui-board-test-draw :document document :id "b-fixture"
                                             :diagram "d-queue")))
      (should (string-match-p "overview › queue" text))
      (should (string-match-p "n-handler" text))
      (should (string-match-p "40, 12 · 1.5x" text)))))

;;;; The event hook

(ert-deftest harness-ui-board-a-change-refreshes-every-open-page ()
  "A board event refreshes open board pages, and no other event does."
  (harness-ui-board-test-with
    (let ((refreshed 0))
      (with-current-buffer (harness-ui-board--list-buffer)
        (harness-ui-boards-mode))
      (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
        (harness-ui-board-mode))
      (cl-letf (((symbol-function 'harness-ui-boards-refresh)
                 (lambda () (cl-incf refreshed)))
                ((symbol-function 'harness-ui-board-refresh)
                 (lambda () (cl-incf refreshed))))
        (harness-ui-board--on-event "board/changed" nil)
        (should (= 2 refreshed))
        (setq refreshed 0)
        (harness-ui-board--on-event "session/changed" nil)
        (should (= 0 refreshed))))))

(ert-deftest harness-ui-board-a-focus-does-not-redraw-a-page ()
  "A focus request is navigation, not a change: the page is not read again."
  (harness-ui-board-test-with
    (let ((refreshed 0))
      (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
        (harness-ui-board-mode))
      (cl-letf (((symbol-function 'harness-ui-board-refresh)
                 (lambda () (cl-incf refreshed))))
        (harness-ui-board--on-event "board/focused" nil)
        (should (= 0 refreshed))))))

(ert-deftest harness-ui-board-a-connection-draws-every-page-again ()
  "When a connection comes, each open page is read again."
  (harness-ui-board-test-with
    (let ((refreshed 0))
      (with-current-buffer (harness-ui-board--list-buffer)
        (harness-ui-boards-mode))
      (with-current-buffer (harness-ui-board--board-buffer "b-fixture")
        (harness-ui-board-mode))
      (cl-letf (((symbol-function 'harness-ui-boards-refresh)
                 (lambda () (cl-incf refreshed)))
                ((symbol-function 'harness-ui-board-refresh)
                 (lambda () (cl-incf refreshed))))
        (harness-ui-board--on-connect)
        (should (= 2 refreshed))))))

;;;; The keys

(ert-deftest harness-ui-board-every-key-has-a-button ()
  "Each key of a page runs the command the page has a button for."
  (harness-ui-board-test-with
    (should (eq (lookup-key harness-ui-boards-mode-map (kbd "g"))
                #'harness-ui-boards-refresh))
    (should (eq (lookup-key harness-ui-boards-mode-map (kbd "a"))
                #'harness-ui-boards-toggle-all))
    (should (eq (lookup-key harness-ui-boards-mode-map (kbd "RET"))
                #'harness-ui-board-open))
    (should (eq (lookup-key harness-ui-board-mode-map (kbd "g"))
                #'harness-ui-board-refresh))
    (should (eq (lookup-key harness-ui-board-mode-map (kbd "RET"))
                #'harness-ui-board-links))
    (should (eq (lookup-key harness-ui-board-mode-map (kbd "s"))
                #'harness-ui-board-snapshot))))

;;;; Pinned revisions

(defconst harness-ui-board-test-pin
  (list :id "pin-1" :board "b-fixture" :task "t-1" :title "the plan"
        :revision 7 :diagram "d-overview" :objects 4 :created 1762700000.0
        :target "harness:board/b-fixture/diagram/d-overview/revision/7"
        :current "harness:board/b-fixture/diagram/d-overview")
  "A pin as `_harness/board/pins' answers it.")

(ert-deftest harness-ui-board-a-pin-is-the-artifact-and-the-board-is-apart ()
  "The pinned section names the revision delivered, and its two ways in."
  (harness-ui-board-test-with
    (let ((text (harness-ui-board-test-draw
                 :document harness-ui-board-test-document
                 :id "b-fixture" :diagram "d-overview" :pins nil)))
      ;; A page that has heard of no pin says so, rather than nothing.
      (should (string-match-p "\n Pinned ─" text))
      (should (string-match-p "no pinned revision" text)))
    (let ((text (harness-ui-board-test-draw
                 :document harness-ui-board-test-document
                 :id "b-fixture" :diagram "d-overview"
                 :pins (list harness-ui-board-test-pin))))
      (should (string-match-p "\n Pinned ─" text))
      (should (string-match-p "the plan" text))
      (should (string-match-p "rev 7" text))
      (should (string-match-p "4 objects" text))
      ;; Two ways in, and their words say which is which: the artifact, and
      ;; the board as it is now.
      (should (string-match-p "\\[Open\\]" text))
      (should (string-match-p "\\[Current board\\]" text))
      (should (equal "the pinned revision, as it was delivered"
                     (harness-ui-board-test-help "[Open]")))
      (should (equal "the board as it is now, not the artifact"
                     (harness-ui-board-test-help "[Current board]"))))))

(provide 'harness-ui-board-test)
;;; harness-ui-board-test.el ends here
