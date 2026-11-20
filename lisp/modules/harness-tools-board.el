;;; harness-tools-board.el --- The board tools an agent works with  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The board tools, the grammar of harness-board.el turned into what an
;; agent can call.  They are not a separate model of the board: each is one
;; bus method of the board module, and each answer is that method's answer.
;;
;;   board.list       board/list     the boards there are, with the id every
;;                                   other tool names
;;   board.create     board/create   a new empty board, in a project
;;   scene.read       board/get      the revision, the selection, every
;;                                   object's exact geometry and text, its
;;                                   local frame and anchors, its resources
;;                                   with the state each resolved to, and,
;;                                   when asked, the rendered picture
;;   grammar.describe board/grammar  the shapes, operations and styles there
;;                                   are, with the units and the limits
;;   scene.edit       board/patch    an ordered batch, validated: the patch,
;;                                   its expanded operations, the ids it
;;                                   creates and changes, the preimages and
;;                                   the diagnostics.  Not a commit.
;;   patch.preview    board/preview  the exact batch rendered and diagnosed
;;   patch.commit     board/commit   one atomic revision, with the read set
;;                                   and an idempotency key
;;   history.undo     board/undo     a compensating edit from the preimages
;;   board.pin        board/pin      a revision kept as a delivered artifact,
;;                                   with its landing diagram, which later
;;                                   edits cannot rewrite
;;   board.pins       board/pins     the artifacts a board delivered, or one
;;                                   of them as the document it kept
;;   board.discuss    board/discuss  a thread of the task's own review,
;;                                   anchored to one place at one revision
;;   board.discussions board/discussions  the threads on a board, and whether
;;                                   the drawing moved since each was written
;;   board.delete     board/delete   a board removed with its client state
;;
;; There is no search tool, no candidate ranking and no lifecycle: an agent
;; reads, decides and edits, and a person decides what the board means.
;; Editing a board never creates a task and never approves code; a task is
;; made only when the person asks for one.
;;
;; The module also carries the skill that explains all of this to an agent
;; (`harness-tools-board-skill-directory'): the skills module lists it
;; exactly while this module is ready.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(declare-function harness-board-link-describe "harness-board-store" (resource))
(declare-function harness-board-svg "harness-board-svg" (board &optional diagram title))
(declare-function harness-board-load "harness-board-store" (id))
(declare-function harness-board--truthy "harness-board" (value))
(declare-function harness-board-new-id "harness-board" (prefix))
(declare-function harness-links-board-url "harness-links" (board &optional diagram object &rest keys))
(declare-function harness-skills-add-module-directory "harness-skills" (module dir &optional origin within))
(defvar harness-directory)

(defun harness-tools-board--call (method &rest args)
  "Call board bus METHOD with ARGS, or say the board module is not loaded."
  (unless (harness-method-exists-p method)
    (error "The board module is not loaded; enable it with `(harness-enable-modules :features board)'"))
  (apply #'harness-call method args))

(defun harness-tools-board--diagram (input)
  "Return the diagram INPUT names, or nil."
  (or (plist-get input :diagram) (plist-get input :diagramId)))

(defun harness-tools-board--scope (input)
  "Return the objects INPUT holds an edit to, or nil for all."
  (let ((scope (plist-get input :scope)))
    (cond ((null scope) nil)
          ((stringp scope) (list scope))
          (t (append scope nil)))))

(defun harness-tools-board--ops (input)
  "Return INPUT's operations, as the board takes them."
  (let ((ops (or (plist-get input :ops) (plist-get input :operations))))
    (unless ops
      (error "An edit needs ops: an array of operations, as grammar.describe lists them"))
    (if (vectorp ops) (append ops nil) ops)))

(defun harness-tools-board--opts (input ctx)
  "Return the board options an edit of INPUT by CTX carries."
  (append (list :session (plist-get ctx :session-id))
          (and (harness-tools-board--diagram input)
               (list :diagram (harness-tools-board--diagram input)))
          (and (harness-tools-board--scope input)
               (list :scope (harness-tools-board--scope input)))))

(defun harness-tools-board--guidance (answer)
  "Return what a patch answer says to do next, for the model."
  (let ((diagnostics (append (plist-get answer :diagnostics) nil))
        (created (append (plist-get answer :created) nil))
        (changed (append (plist-get answer :changed) nil)))
    (concat
     (format "Patch %s · revision %s · %d created · %d changed\n"
             (or (plist-get answer :patch) "?")
             (or (plist-get answer :revision) "?")
             (length created) (length changed))
     (when created (format "Created: %s\n" (string-join created ", ")))
     (when changed (format "Changed: %s\n" (string-join changed ", ")))
     (if diagnostics
         (concat "Diagnostics (warnings, not refusals):\n"
                 (string-join
                  (mapcar (lambda (one)
                            (format "  %s · %s: %s"
                                    (plist-get one :level) (plist-get one :kind)
                                    (plist-get one :message)))
                          diagnostics)
                  "\n"))
       "No diagnostics.")
     "\nNot committed: patch.commit applies exactly this batch.")))

(defun harness-tools-board--error (err)
  "Return the tool result for ERR, a caught board error."
  (let ((kind (harness-board-error-kind err))
        (message (harness-board-error-message err)))
    (harness-tool-error
     (format "%s: %s" (or kind 'refused) message)
     :meta (list :board-error (or kind 'unknown)))))

(defun harness-tools-board--input-board (input)
  "Return the board INPUT names, or nil."
  (or (plist-get input :board) (plist-get input :boardId)))

(defun harness-tools-board--need-board (input what)
  "Return the board INPUT names, or refuse the call of WHAT without one."
  (let ((board (harness-tools-board--input-board input)))
    (unless (and (stringp board) (not (string-blank-p board)))
      (error "%s needs a board: the id board.list returns" what))
    board))

(defun harness-tools-board--project (input ctx)
  "Return the project INPUT names, the calling session's project by default.
An empty name means no project, which is what a board of every project's
work is; the caller's own project is the answer when it names none."
  (let ((named (plist-get input :project)))
    (cond
     ((and (stringp named) (string-blank-p named)) nil)
     ((stringp named) (file-name-as-directory (expand-file-name named)))
     ((null named)
      (let ((cwd (or (plist-get ctx :cwd) default-directory)))
        (and (harness-method-exists-p 'project/root)
             (ignore-errors
               (file-name-as-directory
                (expand-file-name (harness-call 'project/root cwd)))))))
     (t nil))))

(defun harness-tools-board--link (board)
  "Return the harness link to BOARD, or its id when links are not loaded."
  (if (fboundp 'harness-links-board-url)
      (harness-links-board-url board)
    board))

(defun harness-tools-board--scene-svg (board-id diagram)
  "Return the SVG rendering of BOARD-ID's DIAGRAM, or nil.
BOARD-ID names a board; the renderer draws a board document, so it is
loaded here the one way, and nil when it cannot be."
  (when (and (fboundp 'harness-board-svg)
             (harness-method-exists-p 'board/get))
    (ignore-errors
      (harness-board-svg (harness-board-load board-id) diagram))))

;;;; scene.read

(defun harness-tools-board--read (input _ctx)
  "Handler of the scene.read tool: read a board."
  (let* ((board (or (plist-get input :board) (plist-get input :boardId)))
         (diagram (harness-tools-board--diagram input))
         (near (plist-get input :near))
         (nearby (and (harness-board--truthy (plist-get input :nearby)) t)))
    (unless (and (stringp board) (not (string-blank-p board)))
      (error "scene.read needs a board: the id board.list returns"))
    (condition-case err
        (let ((document (harness-tools-board--call
                         'board/get board
                         (append (and near (list :near near))
                                 (and diagram (list :diagram diagram))
                                 (and nearby (list :nearby t))))))
          (harness-tool-ok
           (harness-tools-board--scene-text document)
           :meta (list :board board
                       :diagram (plist-get document :diagram)
                       :revision (plist-get document :revision)
                       :objects (length (plist-get document :objects)))
           :images (let ((svg (harness-tools-board--scene-svg
                               board (plist-get (plist-get document :diagram) :id))))
                     (and svg (list svg)))))
      (harness-board-error (harness-tools-board--error err)))))

(defun harness-tools-board--scene-text (document)
  "Return DOCUMENT, a board as `board/get' reads it, as text for a model.
The text carries the revision, the diagram and its selection, and every
object with its exact geometry and text, its frame, its anchors, its
resources and what each resolved to.  What a drawing shows is not turned
into a claim about a system: an object's role says whether it was
observed, declared, proposed or unknown."
  (let* ((diagram (plist-get document :diagram))
         (objects (append (plist-get document :objects) nil))
         (relationships (append (plist-get document :relationships) nil))
         (nearby (append (plist-get document :nearby) nil)))
    (concat
     (format "board %s · %s · revision %s · theme %s\n"
             (plist-get document :id) (plist-get document :name)
             (plist-get document :revision) (plist-get document :theme))
     (format "diagram %s · %s · viewport %s · selection %s\n"
             (plist-get diagram :id) (plist-get diagram :name)
             (harness-tools-board--viewport (plist-get diagram :viewport))
             (or (let ((selection (append (plist-get diagram :selection) nil)))
                   (and selection (string-join selection ", ")))
                 "none"))
     (format "diagrams: %s\n"
             (string-join (mapcar (lambda (d)
                                    (format "%s (%s)%s"
                                            (plist-get d :id) (plist-get d :name)
                                            (if (plist-get d :parent)
                                                (format " in %s" (plist-get d :parent)) "")))
                                  (append (plist-get document :diagrams) nil))
                          ", "))
     (format "\n%d objects\n" (length objects))
     (mapconcat #'harness-tools-board--object-text objects "\n")
     (if relationships
         (concat (format "\n%d relationships\n" (length relationships))
                 (mapconcat #'harness-tools-board--relationship-text relationships "\n"))
       "\n0 relationships")
     (if nearby
         (concat "\n\nnearby (geometry only, no meaning implied):\n"
                 (mapconcat (lambda (one)
                              (format "  %s · %s · %d units"
                                      (plist-get one :id) (or (plist-get one :name) "")
                                      (plist-get one :distance)))
                            nearby "\n"))
       "")
     "\n")))

(defun harness-tools-board--viewport (viewport)
  "Return VIEWPORT as text."
  (if viewport
      (format "x %s y %s zoom %s" (plist-get viewport :x) (plist-get viewport :y)
              (plist-get viewport :zoom))
    "none"))

(defun harness-tools-board--object-text (object)
  "Return OBJECT, a board object as `board/get' reads it, as one block of text."
  (concat
   (format "· %s · %s%s%s\n"
           (plist-get object :id) (plist-get object :kind)
           (if (plist-get object :name) (format " · %s" (plist-get object :name)) "")
           (if (plist-get object :group) (format " · in group %s" (plist-get object :group)) ""))
   (when (plist-get object :text)
     (format "  text: %s\n" (plist-get object :text)))
   (format "  role: %s%s\n" (plist-get object :role)
           (if (plist-get object :locked) " · locked" ""))
   (format "  shape: %s\n" (harness-tools-board--shape-text (plist-get object :shape)))
   (format "  frame: [%s] · box %s · z %s\n"
           (mapconcat (lambda (v) (format "%s" v)) (append (plist-get object :transform) nil) " ")
           (mapconcat (lambda (v) (format "%s" v)) (plist-get object :box) " ")
           (plist-get object :z))
   (let ((anchors (plist-get object :anchors)))
     (if anchors
         (format "  anchors: %s\n"
                 (mapconcat (lambda (pair)
                              (format "%s [%s %s]" (substring (symbol-name (car pair)) 1)
                                      (aref (cdr pair) 0) (aref (cdr pair) 1)))
                            (cl-loop for (k v) on anchors by #'cddr collect (cons k v)) ", "))
       ""))
   (let ((resources (append (plist-get object :resources) nil)))
     (if resources
         (concat (format "  links: %d\n" (length resources))
                 (mapconcat (lambda (link)
                              (format "    %s %s · %s%s"
                                      (plist-get link :kind) (plist-get link :ref)
                                      (plist-get link :state)
                                      (if-let* ((note (or (plist-get link :note)
                                                          (plist-get link :column)
                                                          (plist-get link :status))))
                                          (format " · %s" note) "")))
                            resources "\n")
                 "\n")
       ""))
   (let ((status (plist-get object :source-status)))
     (if status
         (format "  source: %s · %s\n" (plist-get status :status)
                 (plist-get status :label))
       ""))))

(defun harness-tools-board--shape-text (shape)
  "Return SHAPE as text an agent can read and write back."
  (pcase (plist-get shape :kind)
    ((or "rect" "image")
     (format "%s %sx%s%s" (plist-get shape :kind) (plist-get shape :w) (plist-get shape :h)
             (if (plist-get shape :src) (format " src %s" (plist-get shape :src)) "")))
    ("ellipse" (format "ellipse rx %s ry %s" (plist-get shape :rx) (plist-get shape :ry)))
    ("polygon" (format "polygon %s"
                       (mapconcat (lambda (p) (format "[%s %s]" (aref p 0) (aref p 1)))
                                  (append (plist-get shape :points) nil) " ")))
    ("path" (format "path %s%s"
                    (mapconcat (lambda (segment)
                                 (format "%s %s" (car segment)
                                         (string-join (mapcar (lambda (v) (format "%s" v))
                                                              (cdr segment)) " ")))
                               (plist-get shape :segments) " ")
                    (if (plist-get shape :raw) " · raw ink" "")))
    ("text" (format "text %S size %s" (plist-get shape :text) (plist-get shape :size)))
    (_ "none")))

(defun harness-tools-board--relationship-text (relationship)
  "Return RELATIONSHIP as one block of text."
  (format "· %s · %s · %s\n  %s%s → %s%s%s"
          (plist-get relationship :id) (plist-get relationship :kind)
          (plist-get relationship :diagram)
          (plist-get (plist-get relationship :from) :object)
          (if-let* ((anchor (plist-get (plist-get relationship :from) :anchor)))
              (format ".%s" anchor) "")
          (plist-get (plist-get relationship :to) :object)
          (if-let* ((anchor (plist-get (plist-get relationship :to) :anchor)))
              (format ".%s" anchor) "")
          (if (plist-get relationship :label)
              (format " · %s" (plist-get relationship :label)) "")))

(harness-define-tool "scene.read"
  :label "Read board"
  :description "Read a freeform board: the revision, the diagram's viewport and selection, every object with its exact geometry, text, local frame and anchors, its resource links with the state each resolved to, and the objects near a selection. Nearby is geometry only: it never implies that objects relate architecturally. A drawing states what its roles say -- observed, declared, proposed or unknown."
  :schema '(:type "object"
            :properties (:board (:type "string" :description "The board id, as board.list returns it, or a harness:board/ link.")
                         :diagram (:type "string" :description "The diagram to read; the first when left out.")
                         :near (:type "string" :description "An object id whose nearest neighbours to report.")
                         :nearby (:type "boolean" :description "Report the neighbours of the selected or named object."))
            :required ("board"))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (or (plist-get input :board) (plist-get input :boardId)))
  :handler #'harness-tools-board--read)

;;;; board.list

(defun harness-tools-board--list (input ctx)
  "Handler of the board.list tool: the boards there are."
  (let ((project (harness-tools-board--project input ctx))
        (all (and (harness-board--truthy (plist-get input :all)) t)))
    (condition-case err
        (let ((boards (append (harness-tools-board--call
                               'board/list
                               (append (and project (list :project project))
                                       (and all (list :all t))))
                              nil)))
          (harness-tool-ok (harness-tools-board--list-text boards project all)
                           :meta (list :project project
                                       :boards (length boards))))
      (harness-board-error (harness-tools-board--error err)))))

(defun harness-tools-board--list-text (boards project all)
  "Return BOARDS, as `board/list' reads them, as text for a model.
PROJECT and ALL say which boards were asked for, so an empty answer
names what it left out rather than reading as an empty harness."
  (if (null boards)
      (format "No boards%s.\nA board is made with board.create, and its id is what every other board tool names.\n"
              (cond (all "")
                    (project (format " in %s" project))
                    (t " on this machine")))
    (concat
     (format "%d board%s%s\n\n"
             (length boards) (if (= 1 (length boards)) "" "s")
             (cond (all " · every project")
                   (project (format " · %s" project))
                   (t "")))
     (mapconcat #'harness-tools-board--board-line boards "\n")
     "\n\nRead one with scene.read, naming its id.")))

(defun harness-tools-board--board-line (board)
  "Return BOARD, a `board/list' entry, as one line of text."
  (format "· %s · %s\n  %s%s · revision %s · %s objects in %s diagram%s · updated %s"
          (plist-get board :id)
          (or (plist-get board :name) "")
          (or (plist-get board :theme) "no theme")
          (if-let* ((project (plist-get board :project)))
              (format " · %s" project) "")
          (or (plist-get board :revision) 0)
          (or (plist-get board :objects) 0)
          (or (plist-get board :diagrams) 0)
          (if (= 1 (or (plist-get board :diagrams) 0)) "" "s")
          (or (and (plist-get board :updated)
                   (harness-relative-time (plist-get board :updated)))
              "never")))

(harness-define-tool "board.list"
  :label "List boards"
  :description "List the freeform boards the harness keeps, newest first, with the id every other board tool names: the board's name, its theme, its revision, how many objects and diagrams it holds, its project and when it last changed. A board of the calling session's project is listed by default; name a project to list another's, or all to list every board. A board is made with board.create, and read with scene.read."
  :schema '(:type "object"
            :properties (:project (:type "string" :description "The project whose boards to list; the calling session's own by default. An empty name lists every board, as all does.")
                         :all (:type "boolean" :description "List every board, whatever its project.")))
  :kind 'read
  :coalescable t
  :handler #'harness-tools-board--list)

;;;; board.create

(defun harness-tools-board--create (input ctx)
  "Handler of the board.create tool: make a board."
  (let* ((name (or (plist-get input :name) (plist-get input :title)))
         (id (or (plist-get input :board) (plist-get input :id)
                 (and (stringp name) (not (string-blank-p name))
                      (harness-board-new-id "b"))))
         (project (harness-tools-board--project input ctx))
         (theme (harness-tools-board--string (plist-get input :theme)))
         (writers (append (plist-get input :writers) nil)))
    (unless (and (stringp id) (not (string-blank-p id)))
      (error "board.create needs a name, or an id to make the board with"))
    (condition-case err
        (let* ((document (harness-tools-board--call
                          'board/create id (or name id)
                          (append (and project (list :project project))
                                  (and theme (list :theme theme))
                                  (and writers (list :writers writers)))))
               (board (plist-get document :id)))
          (harness-tool-ok
           (concat
            (format "Made board %s · %s%s%s\n"
                    board (or (plist-get document :name) "")
                    (if project (format " · %s" project) " · no project")
                    (format " · theme %s" (or (plist-get document :theme) "")))
            (format "It has one empty diagram, %s, and revision %s.\n"
                    (or (plist-get (plist-get document :diagram) :id) "d-overview")
                    (or (plist-get document :revision) 0))
            (format "Draw on it with scene.edit, then patch.commit; read it with scene.read %s.\n"
                    board)
            (format "Board link: %s" (harness-tools-board--link board)))
           :meta (list :board board
                       :name (plist-get document :name)
                       :project (plist-get document :project)
                       :theme (plist-get document :theme)
                       :revision (plist-get document :revision)
                       :diagram (plist-get (plist-get document :diagram) :id)
                       :link (harness-tools-board--link board))))
      (harness-board-error (harness-tools-board--error err)))))

(harness-define-tool "board.create"
  :label "Create board"
  :description "Make a new, empty freeform board and return its id, its diagram and its link: one diagram with no objects, at revision 0, ready for scene.edit. A board is a freeform place to think -- notes, ink, shapes and diagrams -- not a task and not a review: making one creates no task and approves no code. A board is grouped with the calling session's project unless a project is named, or unless the project is left empty for one that belongs to no project. An id already in use is refused rather than emptied; board.list says which ids there are."
  :schema '(:type "object"
            :properties (:name (:type "string" :description "What the board is called, for people.")
                         :id (:type "string" :description "The board's id: letters, digits and .:- . A fresh one is made from the name when left out.")
                         :project (:type "string" :description "The project the board belongs to; the calling session's own by default. An empty name makes a board of no project.")
                         :theme (:type "string" :description "The theme to wear; electric-commons by default. grammar.describe lists them.")
                         :writers (:type "array" :items (:type "string")
                                   :description "The sessions that may edit it; every session by default."))
            :required ("name"))
  :kind 'write
  :subject (lambda (input) (or (plist-get input :name) (plist-get input :id)))
  :handler #'harness-tools-board--create)

;;;; grammar.describe

(defun harness-tools-board--grammar (_input _ctx)
  "Handler of the grammar.describe tool."
  (condition-case err
      (let ((grammar (harness-tools-board--call 'board/grammar)))
        (harness-tool-ok (harness-tools-board--grammar-text grammar)
                         :meta (list :shapes (length (plist-get grammar :shapes))
                                     :operations (length (plist-get grammar :operations))
                                     :themes (length (plist-get grammar :themes)))))
    (harness-board-error (harness-tools-board--error err))))

(defun harness-tools-board--grammar-text (grammar)
  "Return GRAMMAR as text for a model."
  (concat
   (format "board grammar · schema %s\n" (plist-get grammar :schema))
   (format "units: x %s, y %s, angles %s, scale %s\n"
           (plist-get (plist-get grammar :units) :x)
           (plist-get (plist-get grammar :units) :y)
           (plist-get (plist-get grammar :units) :angle)
           (plist-get (plist-get grammar :units) :scale))
   (format "limits: coordinate %s, movement budget %s, undo depth %s\n"
           (plist-get (plist-get grammar :limits) :coordinate)
           (plist-get (plist-get grammar :limits) :movement)
           (plist-get (plist-get grammar :limits) :undo-depth))
   (format "\nshapes: %s\n"
           (string-join (mapcar (lambda (s)
                                  (format "%s (%s)" (plist-get s :kind)
                                          (string-join (append (plist-get s :fields) nil) " ")))
                                (append (plist-get grammar :shapes) nil))
                        ", "))
   (format "path commands: %s\n"
           (string-join (mapcar (lambda (c) (format "%s takes %s numbers"
                                                    (plist-get c :command)
                                                    (plist-get c :numbers)))
                                (append (plist-get grammar :path-commands) nil))
                        ", "))
   (format "\nobjects: %s\n"
           (string-join (mapcar (lambda (o) (format "%s -- %s" (plist-get o :kind) (plist-get o :doc)))
                                (append (plist-get grammar :objects) nil))
                        "\n  "))
   (format "\noperations: %s\n"
           (string-join (mapcar (lambda (o) (format "%s -- %s" (plist-get o :op) (plist-get o :doc)))
                                (append (plist-get grammar :operations) nil))
                        "\n  "))
   (format "\nstyle keys: %s\n" (string-join (append (plist-get grammar :styles) nil) ", "))
   (format "colours: %s\n" (string-join (append (plist-get grammar :colors) nil) ", "))
   (format "themes: %s\n"
           (string-join (mapcar (lambda (theme) (plist-get theme :name))
                                (append (plist-get grammar :themes) nil))
                        ", "))
   (format "\nresources: %s\n"
           (string-join (mapcar (lambda (r) (format "%s -- %s" (plist-get r :kind) (plist-get r :doc)))
                                (append (plist-get grammar :resources) nil)) ", "))
   (format "roles: %s\n"
           (string-join (mapcar (lambda (r) (format "%s -- %s" (plist-get r :role) (plist-get r :doc)))
                                (append (plist-get grammar :roles) nil)) "\n  "))
   (format "\nerrors: %s\n"
           (string-join (mapcar (lambda (e) (format "%s -- %s" (plist-get e :error) (plist-get e :doc)))
                                (append (plist-get grammar :errors) nil)) "\n  "))
   (format "\ntransforms: %s\nconstraints: %s\n"
           (string-join (append (plist-get grammar :transforms) nil) ", ")
           (string-join (append (plist-get grammar :constraints) nil) ", "))
   (format "attach order: %s\n"
           (string-join (append (plist-get grammar :attachment-order) nil) ", "))))

(harness-define-tool "grammar.describe"
  :label "Describe board grammar"
  :description "Read the board grammar: the shape kinds and their fields, the operations a patch may apply, the style keys and colour roles, the themes, the resource kinds, the evidence roles, the units and limits, and the distinct ways an operation is refused. Every board and theme is built from exactly these; there is no renderer-only primitive and no other edit path."
  :schema '(:type "object" :properties (:empty (:type "boolean")))
  :kind 'read
  :coalescable t
  :handler #'harness-tools-board--grammar)

;;;; scene.edit

(defun harness-tools-board--edit (input ctx)
  "Handler of the scene.edit tool."
  (let ((board (or (plist-get input :board) (plist-get input :boardId))))
    (unless (and (stringp board) (not (string-blank-p board)))
      (error "scene.edit needs a board: the id board.list returns"))
    (condition-case err
        (let ((answer (harness-tools-board--call
                       'board/patch board (harness-tools-board--ops input)
                       (harness-tools-board--opts input ctx))))
          (harness-tool-ok (harness-tools-board--guidance answer)
                           :meta (list :board board
                                       :patch (plist-get answer :patch)
                                       :hash (plist-get answer :hash)
                                       :revision (plist-get answer :revision))))
      (harness-board-error (harness-tools-board--error err)))))

(harness-define-tool "scene.edit"
  :label "Edit board"
  :description "Apply an ordered batch of explicit operations to a board and return the validated patch: the expanded operations, the ids it creates and changes, the preimages it would replace, and diagnostics. Nothing is committed: patch.commit applies this exact patch. Hard constraints (a locked object, the scope, a movement budget) refuse the whole batch and name a distinct error kind; soft findings (text overflow, an object moving far, an overlap nobody declared) are warnings and the batch still stands. Overlap is allowed unless you ask otherwise. Editing a board never creates a task and never approves code."
  :schema '(:type "object"
            :properties (:board (:type "string" :description "The board id.")
                         :diagram (:type "string" :description "The diagram the operations default to.")
                         :scope (:type "array" :items (:type "string")
                                 :description "The object ids this edit may touch. An operation naming anything else is refused before it applies.")
                         :ops (:type "array"
                               :items (:type "object"
                                       :properties (:op (:type "string")
                                                    :id (:type "string")
                                                    :diagram (:type "string")
                                                    :kind (:type "string")
                                                    :parent (:type "string")
                                                    :childAnchor (:type "string")
                                                    :parentAnchor (:type "string")
                                                    :child-anchor (:type "string")
                                                    :parent-anchor (:type "string")
                                                    :angle (:type "number")
                                                    :scale (:type "number")
                                                    :mirror (:type "boolean")
                                                    :text (:type "string")
                                                    :name (:type "string")
                                                    :role (:type "string")
                                                    :locked (:type "boolean")
                                                    :x (:type "number")
                                                    :y (:type "number")
                                                    :dx (:type "number")
                                                    :dy (:type "number")
                                                    :budget (:type "number")
                                                    :pivot (:type "array" :items (:type "number"))
                                                    :sx (:type "number")
                                                    :sy (:type "number")
                                                    :axis (:type "string")
                                                    :matrix (:type "array" :items (:type "number"))
                                                    :transform (:type "array" :items (:type "number"))
                                                    :shape (:type "object")
                                                    :style (:type "object")
                                                    :anchors (:type "object")
                                                    :resources (:type "array" :items (:type "object"))
                                                    :task (:type "string")
                                                    :members (:type "array" :items (:type "string"))
                                                    :selection (:type "array" :items (:type "string"))
                                                    :portals (:type "array" :items (:type "object"))
                                                    :viewport (:type "object")
                                                    :theme (:type "string")
                                                    :newId (:type "string")
                                                    :new-id (:type "string")
                                                    :from (:type "object")
                                                    :to (:type "object")
                                                    :label (:type "string")
                                                    :z (:type "number")
                                                    :on (:type "boolean"))
                                       :description "One operation: its op name, the ids it names and the fields that operation takes, as grammar.describe lists them.")
                               :description "The operations, in the order they apply; each validated against the document as the ones before it leave it."))
            :required ("board" "ops"))
  :kind 'write
  :subject (lambda (input) (or (plist-get input :board) (plist-get input :boardId)))
  :handler #'harness-tools-board--edit)

;;;; patch.preview

(defun harness-tools-board--preview (input ctx)
  "Handler of the patch.preview tool."
  (let ((board (or (plist-get input :board) (plist-get input :boardId))))
    (unless (and (stringp board) (not (string-blank-p board)))
      (error "patch.preview needs a board"))
    (condition-case err
        (let ((answer (harness-tools-board--call
                       'board/preview board (harness-tools-board--ops input)
                       (harness-tools-board--opts input ctx))))
          (harness-tool-ok (harness-tools-board--guidance answer)
                           :meta (list :board board
                                       :patch (plist-get answer :patch)
                                       :hash (plist-get answer :hash)
                                       :revision (plist-get answer :revision))
                           :images (let ((svg (harness-tools-board--scene-svg
                                               board (or (harness-tools-board--diagram input)
                                                         (plist-get (plist-get (plist-get answer :document)
                                                                               :diagram)
                                                                    :id)))))
                                     (and svg (list svg)))))
      (harness-board-error (harness-tools-board--error err)))))

(harness-define-tool "patch.preview"
  :label "Preview board patch"
  :description "Render the exact operation batch without changing anything, and report what it would do: the patch and its content hash, the objects it creates and moves and by how much, text that would overflow, references that would break, and constraint failures. Use it when the drawing matters; the caller decides the next edit. Nothing is written, and no revision is made."
  :schema '(:type "object"
            :properties (:board (:type "string" :description "The board id.")
                         :diagram (:type "string" :description "The diagram the operations default to.")
                         :scope (:type "array" :items (:type "string")
                                 :description "The object ids this batch may touch.")
                         :ops (:type "array" :items (:type "object")
                               :description "The operations, in the order they apply, as scene.edit takes them."))
            :required ("board" "ops"))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (or (plist-get input :board) (plist-get input :boardId)))
  :handler #'harness-tools-board--preview)

;;;; patch.commit

(defun harness-tools-board--commit (input ctx)
  "Handler of the patch.commit tool."
  (let ((board (or (plist-get input :board) (plist-get input :boardId)))
        (key (or (plist-get input :idempotencyKey) (plist-get input :key))))
    (unless (and (stringp board) (not (string-blank-p board)))
      (error "patch.commit needs a board"))
    (condition-case err
        (let ((answer (harness-tools-board--call
                       'board/commit board
                       (plist-get input :patch)
                       (or (plist-get input :hash) (plist-get input :patchHash))
                       (plist-get input :revision)
                       (append (harness-tools-board--opts input ctx)
                               (and key (list :key key))
                               (and (plist-get input :ops)
                                    (list :ops (harness-tools-board--ops input)))))))
          (harness-tool-ok
           (format "%sPatch %s committed at revision %s%s.\n%s"
                   (if (plist-get answer :idempotent) "Already committed: " "")
                   (or (plist-get answer :patch) "?")
                   (or (plist-get answer :revision) "?")
                   (if (plist-get answer :idempotent)
                       " (the key named a commit that already happened)" "")
                   (harness-tools-board--diagnostics-text (plist-get answer :diagnostics)))
           :meta (list :board board
                       :patch (plist-get answer :patch)
                       :revision (plist-get answer :revision)
                       :idempotent (and (plist-get answer :idempotent) t))))
      (harness-board-error (harness-tools-board--error err)))))

(defun harness-tools-board--diagnostics-text (diagnostics)
  "Return DIAGNOSTICS as text."
  (let ((all (append diagnostics nil)))
    (if all
        (concat "\nDiagnostics:\n"
                (string-join
                 (mapcar (lambda (one) (format "  %s · %s: %s"
                                               (plist-get one :level)
                                               (plist-get one :kind)
                                               (plist-get one :message)))
                         all)
                 "\n"))
      "")))

(harness-define-tool "patch.commit"
  :label "Commit board patch"
  :description "Apply a validated patch to a board as one atomic revision. Name the patch id and content hash that patch.preview or scene.edit returned, and the revision you read: if the board moved since, the whole batch is refused as stale-revision rather than applied over somebody else's work. Revalidation happens against the current document before anything is written. Pass an idempotencyKey so a retried call after a lost answer commits once: a key used before answers what it answered then."
  :schema '(:type "object"
            :properties (:board (:type "string" :description "The board id.")
                         :patch (:type "string" :description "The patch id scene.edit or patch.preview returned.")
                         :hash (:type "string" :description "The content hash that patch came with.")
                         :revision (:type "number" :description "The revision the batch was made against, which is the revision you read.")
                         :ops (:type "array" :items (:type "object")
                               :description "The operations again, when the patch id is not to hand: they are revalidated whole before anything is written.")
                         :diagram (:type "string" :description "The diagram the operations default to.")
                         :scope (:type "array" :items (:type "string")
                                 :description "The object ids the batch may touch.")
                         :idempotencyKey (:type "string" :description "A key for this batch: a retried call with the same key commits once and answers what it answered then."))
            :required ("board" "revision"))
  :kind 'write
  :subject (lambda (input) (or (plist-get input :board) (plist-get input :boardId)))
  :handler #'harness-tools-board--commit)

;;;; history.undo

(defun harness-tools-board--undo (input ctx)
  "Handler of the history.undo tool."
  (let ((board (or (plist-get input :board) (plist-get input :boardId))))
    (unless (and (stringp board) (not (string-blank-p board)))
      (error "history.undo needs a board"))
    (condition-case err
        (let ((answer (harness-tools-board--call
                       'board/undo board
                       (append (list :session (plist-get ctx :session-id))
                               (and (plist-get input :revision)
                                    (list :revision (plist-get input :revision)))
                               (and (harness-board--truthy (plist-get input :dryRun))
                                    (list :dry-run t))))))
          (harness-tool-ok (harness-tools-board--undo-text answer)
                           :meta (list :board board
                                       :revision (plist-get answer :revision)
                                       :dry-run (and (plist-get answer :dry-run) t))))
      (harness-board-error (harness-tools-board--error err)))))

(defun harness-tools-board--undo-text (answer)
  "Return what a `board/undo' ANSWER did, in words for a model."
  (let ((conflicts (append (plist-get answer :conflicts) nil))
        (ops (append (plist-get answer :ops) nil)))
    (concat
     (format "%s %d operation%s · revision %s\n"
             (if (plist-get answer :dry-run) "Would apply" "Applied")
             (length ops) (if (= (length ops) 1) "" "s")
             (plist-get answer :revision))
     (if (plist-get answer :undone)
         (format "Taking back revision %s.\n" (plist-get answer :undone)) "")
     (if ops
         (concat "Operations: "
                 (string-join
                  (mapcar (lambda (op)
                            (format "%s %s" (plist-get op :op) (plist-get op :id)))
                          ops)
                  ", ")
                 "\n")
       "")
     (if conflicts
         (concat "Conflicts, kept as they are (somebody's work since):\n"
                 (string-join
                  (mapcar (lambda (conflict)
                            (format "  %s: %s" (plist-get conflict :id)
                                    (plist-get conflict :reason)))
                          conflicts)
                  "\n"))
       "No conflicts."))))

(harness-define-tool "history.undo"
  :label "Undo board edit"
  :description "Take back the newest commit of a board, or the one you name, as a compensating edit built from the preimages that commit kept. An object somebody else changed since is left as it is and reported as a conflict: undo never rewrites another writer's work. With dryRun, return the operations without committing them."
  :schema '(:type "object"
            :properties (:board (:type "string" :description "The board id.")
                         :revision (:type "number" :description "The commit to take back; the newest by default.")
                         :dryRun (:type "boolean" :description "Return the operations without committing them."))
            :required ("board"))
  :kind 'write
  :subject (lambda (input) (or (plist-get input :board) (plist-get input :boardId)))
  :handler #'harness-tools-board--undo)

(defun harness-tools-board--session-task (ctx)
  "Return the task CTX's session works on, or nil."
  (let ((session (plist-get ctx :session-id)))
    (when (and session (harness-method-exists-p 'task/for-session))
      (let ((task (ignore-errors (harness-call 'task/for-session session))))
        (plist-get task :id)))))

(defun harness-tools-board--string (value)
  "Return VALUE as a string, or nil."
  (cond ((null value) nil)
        ((stringp value) (and (not (string-blank-p value)) value))
        ((keywordp value) (substring (symbol-name value) 1))
        ((or (numberp value) (symbolp value)) (format "%s" value))
        (t nil)))

(defun harness-tools-board--pin (input ctx)
  "Handler of the board.pin tool: pin a board revision for a task."
  (let ((board (or (plist-get input :board) (plist-get input :boardId))))
    (unless (and (stringp board) (not (string-blank-p board)))
      (error "board.pin needs a board: the id board.list returns"))
    (condition-case err
        (let* ((task (or (harness-tools-board--string (plist-get input :task))
                         (harness-tools-board--session-task ctx)))
               (pin (harness-tools-board--call
                     'board/pin board
                     (append (and task (list :task task))
                             (and (harness-tools-board--diagram input)
                                  (list :diagram (harness-tools-board--diagram input)))
                             (and (plist-get input :object)
                                  (list :object (plist-get input :object)))
                             (and (plist-get input :title)
                                  (list :title (plist-get input :title)))))))
          (harness-tool-ok
           (concat
            (format "Pinned revision %s of %s as %s, landing in %s.\n"
                    (plist-get pin :revision) (plist-get pin :board) (plist-get pin :id)
                    (or (plist-get pin :diagram) "its first diagram"))
            (format "Artifact: %s\nCurrent board: %s\n"
                    (or (plist-get pin :target) "") (or (plist-get pin :current) ""))
            (format "The artifact holds %s objects of revision %s; edits since do not reach it.\n"
                    (plist-get pin :objects) (plist-get pin :revision)))
           :meta (list :board board
                       :pin (plist-get pin :id)
                       :revision (plist-get pin :revision)
                       :diagram (plist-get pin :diagram)
                       :target (plist-get pin :target)
                       :current (plist-get pin :current))))
      (harness-board-error (harness-tools-board--error err)))))

(harness-define-tool "board.pin"
  :label "Pin board revision"
  :description "Pin a board's current revision as a task's delivered architecture, with its landing diagram. The pin keeps its own copy of the drawing, so later edits cannot rewrite what was handed in; the answer names the artifact's link and, separately, the board as it goes on. Use it when a task's explanation is a drawing. It neither accepts the drawing nor approves any code, and resolving a discussion stays a separate action."
  :schema '(:type "object"
            :properties (:board (:type "string" :description "The board id.")
                         :task (:type "string" :description "The task the artifact is delivered for; the calling session's own task by default.")
                         :diagram (:type "string" :description "The landing diagram.")
                         :object (:type "string" :description "The place on the landing diagram to open.")
                         :title (:type "string" :description "What the delivered artifact is called."))
            :required ("board"))
  :kind 'write
  :subject (lambda (input) (or (plist-get input :board) (plist-get input :boardId)))
  :handler #'harness-tools-board--pin)

;;;; board.pins

(defun harness-tools-board--pins (input _ctx)
  "Handler of the board.pins tool: the artifacts a board delivered."
  (let ((board (harness-tools-board--need-board input "board.pins"))
        (pin (harness-tools-board--string (plist-get input :pin)))
        (task (harness-tools-board--string (plist-get input :task))))
    (condition-case err
        (let ((answer (harness-tools-board--call
                       'board/pins board
                       (append (and pin (list :pin pin))
                               (and task (list :task task))))))
          (if pin
              (harness-tool-ok
               (harness-tools-board--pin-document-text board answer)
               :meta (list :board board
                           :pin (plist-get (plist-get answer :pin) :id)
                           :revision (plist-get (plist-get answer :pin) :revision))
               :images (let ((image (plist-get answer :image)))
                         (and (stringp image) (list image))))
            (let ((pins (append answer nil)))
              (harness-tool-ok (harness-tools-board--pins-text board pins)
                               :meta (list :board board :pins (length pins))))))
      (harness-board-error (harness-tools-board--error err)))))

(defun harness-tools-board--pins-text (board pins)
  "Return PINS, the artifacts of BOARD, as text for a model."
  (if (null pins)
      (format "No pinned revision of %s.\nboard.pin keeps one, with its landing diagram, as a task's delivered drawing.\n"
              board)
    (concat
     (format "%d pinned revision%s of %s, newest first\n\n"
             (length pins) (if (= 1 (length pins)) "" "s") board)
     (mapconcat #'harness-tools-board--pin-line pins "\n")
     "\n\nName one with pin to read the document it kept.")))

(defun harness-tools-board--pin-line (pin)
  "Return PIN, a `board/pins' entry, as one line of text."
  (let ((objects (or (plist-get pin :objects) 0)))
    (format "· %s · %s · revision %s in %s · %s object%s\n  %s\n  artifact: %s\n  board now: %s"
            (plist-get pin :id)
            (or (plist-get pin :title) "untitled")
            (or (plist-get pin :revision) 0)
            (or (plist-get pin :diagram) "its first diagram")
            objects
            (if (= 1 objects) "" "s")
            (mapconcat #'identity
                       (delq nil
                             (list (if-let* ((task (plist-get pin :task)))
                                       (format "task %s" task)
                                     "no task")
                                   (and (plist-get pin :created)
                                        (harness-relative-time
                                         (float-time (plist-get pin :created))))))
                       " · ")
            (or (plist-get pin :target) "")
            (or (plist-get pin :current) ""))))

(defun harness-tools-board--pin-document-text (board answer)
  "Return the pinned document of BOARD in ANSWER as text for a model.
It is the drawing as it was pinned, read from the snapshot rather than
from the board: an edit since cannot reach it."
  (let ((pin (plist-get answer :pin))
        (document (plist-get answer :document))
        (objects (or (plist-get (plist-get answer :pin) :objects) 0)))
    (concat
     (format "Pin %s · %s · revision %s of %s · %s object%s\n"
             (plist-get pin :id) (or (plist-get pin :title) "untitled")
             (plist-get pin :revision) board objects
             (if (= 1 objects) "" "s"))
     (format "Artifact: %s\nCurrent board: %s\n"
             (or (plist-get pin :target) "") (or (plist-get pin :current) ""))
     (if (and (plist-get pin :revision)
              (plist-get document :revision)
              (not (equal (plist-get pin :revision) (plist-get document :revision))))
         "The snapshot says its own revision; it is the artifact, not the board.\n"
       "")
     (harness-tools-board--scene-text document))))

(harness-define-tool "board.pins"
  :label "Read pinned revisions"
  :description "Read the revisions a board delivered as artifacts, newest first: each pin's id, its title, the task it was delivered for, the revision it kept, its landing diagram and how many objects it holds, with the artifact's link kept apart from the board as it goes on. Name one pin to read the document it kept, exactly as it was pinned, with a picture: an edit since cannot reach it. board.pin makes one."
  :schema '(:type "object"
            :properties (:board (:type "string" :description "The board id, as board.list returns it.")
                         :pin (:type "string" :description "One pin to read, as a document, with its picture.")
                         :task (:type "string" :description "Keep the pins one task delivered."))
            :required ("board"))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (or (plist-get input :board) (plist-get input :boardId)))
  :handler #'harness-tools-board--pins)

;;;; board.discussions

(defun harness-tools-board--discussions (input _ctx)
  "Handler of the board.discussions tool: the threads on a board."
  (let ((board (harness-tools-board--need-board input "board.discussions"))
        (task (harness-tools-board--string (plist-get input :task)))
        (object (or (plist-get input :object) (plist-get input :objectId))))
    (condition-case err
        (let ((threads (append (harness-tools-board--call
                                'board/discussions board
                                (append (and task (list :task task))
                                        (and object (list :object object))))
                               nil)))
          (harness-tool-ok (harness-tools-board--discussions-text board threads)
                           :meta (list :board board :threads (length threads))))
      (harness-board-error (harness-tools-board--error err)))))

(defun harness-tools-board--discussions-text (board threads)
  "Return THREADS, the discussions of BOARD, as text for a model."
  (if (null threads)
      (format "No discussion on %s.\nboard.discuss starts one on a node, a connector or the diagram.\n"
              board)
    (concat
     (format "%d discussion%s on %s\n\n"
             (length threads) (if (= 1 (length threads)) "" "s") board)
     (mapconcat #'harness-tools-board--discussion-line threads "\n")
     "\n\nThe thread is the task's review's own: it is replied to and resolved there.")))

(defun harness-tools-board--discussion-line (thread)
  "Return THREAD, a `board/discussions' entry, as one line of text."
  (format "· %s · %s · on %s%s · written at revision %s%s · %s comment%s%s"
          (plist-get thread :id) (or (plist-get thread :status) "open")
          (or (plist-get thread :name) "the diagram")
          (if-let* ((diagram (plist-get thread :diagram)))
              (format " in %s" diagram) "")
          (or (plist-get thread :revision) 0)
          (cond ((plist-get thread :gone) " · the object is gone")
                ((plist-get thread :stale) " · the drawing has moved since")
                (t ""))
          (or (plist-get thread :comments) 0)
          (if (= 1 (or (plist-get thread :comments) 0)) "" "s")
          (if-let* ((task (plist-get thread :task))) (format " · task %s" task) "")))

(harness-define-tool "board.discussions"
  :label "Read board discussions"
  :description "Read the discussions on a board, newest first: each thread's id and status, the place it is anchored to, the revision it was written against and whether the drawing has moved since, or the object it names is gone, how many comments it holds and the task whose review holds it. The threads are the review's own, so they are read, replied to and resolved there. board.discuss starts or answers one."
  :schema '(:type "object"
            :properties (:board (:type "string" :description "The board id, as board.list returns it.")
                         :task (:type "string" :description "Keep the threads of one task's review.")
                         :object (:type "string" :description "Keep the threads on one object."))
            :required ("board"))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (or (plist-get input :board) (plist-get input :boardId)))
  :handler #'harness-tools-board--discussions)

;;;; board.delete

(defun harness-tools-board--delete (input _ctx)
  "Handler of the board.delete tool: remove a board."
  (let ((board (harness-tools-board--need-board input "board.delete"))
        (force (and (harness-board--truthy (plist-get input :force)) t)))
    (condition-case err
        (let* ((answer (harness-tools-board--call
                        'board/delete board (list :force force)))
               (pins (if (consp answer) (plist-get answer :pins) 0)))
          (harness-tool-ok
           (concat
            (format "Deleted board %s, and the client state navigation kept for it.\n" board)
            (if pins
                (format "Its %d pinned revision%s went with it: an artifact names the board it came from.\n"
                        pins (if (= 1 pins) "" "s"))
              "It had no pinned revision.\n")
            "The board is gone for good: no revision records this, and history.undo has nothing to take back.\n")
           :meta (list :board board :deleted t :pins pins)))
      (harness-board-error (harness-tools-board--error err)))))

(harness-define-tool "board.delete"
  :label "Delete board"
  :description "Delete a board and the client state navigation kept for it. A board a task delivered a pinned revision of is refused unless force is set, and then its pins go with it: an artifact names the board it came from. Deleting is not an edit -- nothing of the board is left to undo and no revision records it -- so use it for a board made by mistake, not to take back a drawing: history.undo takes back a commit."
  :schema '(:type "object"
            :properties (:board (:type "string" :description "The board id, as board.list returns it.")
                         :force (:type "boolean" :description "Delete a board a task delivered, with its pinned revisions."))
            :required ("board"))
  :kind 'write
  :subject (lambda (input) (or (plist-get input :board) (plist-get input :boardId)))
  :handler #'harness-tools-board--delete)

;;;; board.discuss

(defun harness-tools-board--discuss (input ctx)
  "Handler of the board.discuss tool: start or answer a thread on a place."
  (let ((board (or (plist-get input :board) (plist-get input :boardId)))
        (object (or (plist-get input :object) (plist-get input :objectId))))
    (unless (and (stringp board) (not (string-blank-p board)))
      (error "board.discuss needs a board: the id board.list returns"))
    (unless (and (stringp object) (not (string-blank-p object)))
      (error "board.discuss needs an object: a node, a connector or the diagram"))
    (condition-case err
        (let* ((diagram (harness-tools-board--diagram input))
               (answer (harness-tools-board--call
                        'board/discuss board object
                        (append (list :session (plist-get ctx :session-id)
                                      :call-id (plist-get ctx :call-id))
                                (and diagram (list :diagram diagram))
                                (and (plist-get input :task)
                                     (list :task (plist-get input :task)))
                                (and (plist-get input :text)
                                     (list :text (plist-get input :text)))
                                (and (plist-get input :thread)
                                     (list :thread (plist-get input :thread)))))))
          (harness-tool-ok
           (format "Thread %s · %s · on %s of %s at revision %s.\n%s\n"
                   (plist-get answer :thread) (or (plist-get answer :status) "open")
                   (or (plist-get answer :object) "the diagram")
                   (plist-get answer :board) (plist-get answer :revision)
                   (if (plist-get input :thread)
                       "Answered in the review's own thread."
                     "A thread of the task's review, not a comment store beside it."))
           :meta (list :board board
                       :thread (plist-get answer :thread)
                       :object (plist-get answer :object)
                       :revision (plist-get answer :revision))))
      (harness-board-error (harness-tools-board--error err)))))

(harness-define-tool "board.discuss"
  :label "Discuss board place"
  :description "Start or answer a discussion on one place of a board: a node, a connector or the diagram itself. The thread is a native thread of the task's review, so it is replied to, resolved and read there like any other; it keeps the board, the diagram, the object and the revision it was written against, so the anchor survives a move or a rename and a drawing that has changed since says so. Resolving the thread, accepting a change to the drawing and approving code stay three separate actions."
  :schema '(:type "object"
            :properties (:board (:type "string" :description "The board id.")
                         :object (:type "string" :description "The object, connector or diagram discussed.")
                         :task (:type "string" :description "The task whose review holds the thread.")
                         :diagram (:type "string" :description "The diagram the object is seen in.")
                         :text (:type "string" :description "What to say.")
                         :thread (:type "string" :description "A thread to answer instead of starting one."))
            :required ("board" "object" "task"))
  :kind 'write
  :subject (lambda (input) (or (plist-get input :board) (plist-get input :boardId)))
  :handler #'harness-tools-board--discuss)

;;;; The skill this module brings

;; The board is a place an agent works in through nine tools, and the
;; order they are used in is not obvious from any one description: read
;; the grammar, make a board, read it, propose an edit, preview it,
;; commit it, undo it, pin what was delivered, discuss a place.  So the
;; module carries a skill that says how, and the skills module lists it
;; exactly while this module is ready.

(defcustom harness-tools-board-skill-directory nil
  "Where the skill the board tools bring is kept, or nil for the harness's own.
nil means the `skills' directory of the harness tree this module was
loaded from (`harness-directory'), which holds the `freeform-board'
skill.  A directory holding skills is what to name, not one skill's own
directory: every skill under it is listed."
  :type '(choice (const :tag "The harness's own skills" nil) directory)
  :group 'harness)

(defun harness-tools-board--skill-directory ()
  "Return the directory of skills the board tools bring, or nil.
It is `harness-tools-board-skill-directory' when set, else the `skills'
directory of the harness tree, when that tree is known and the directory
is there.  A harness that loads this module without `harness-directory'
simply brings no skill, rather than guessing where one is."
  (or (and (stringp harness-tools-board-skill-directory)
           (not (string-blank-p harness-tools-board-skill-directory))
           (file-name-as-directory
            (expand-file-name harness-tools-board-skill-directory)))
      (and (stringp harness-directory)
           (let ((dir (expand-file-name "skills" harness-directory)))
             (and (file-directory-p dir) (file-name-as-directory dir))))))

(defun harness-tools-board--init ()
  "Have the skills module list this module's skill while this module is ready."
  (with-eval-after-load 'harness-skills
    (when-let* ((dir (harness-tools-board--skill-directory)))
      (harness-skills-add-module-directory 'tools-board dir "harness" harness-directory))))

(harness-define-module 'tools-board
  :doc "The board tools an agent works with: board.list, board.create, scene.read, grammar.describe, scene.edit, patch.preview, patch.commit, history.undo, board.pin, board.pins, board.discuss, board.discussions and board.delete, and the skill that explains them."
  :requires '(board-store tools)
  :init #'harness-tools-board--init)

(provide 'harness-tools-board)
;;; harness-tools-board.el ends here
