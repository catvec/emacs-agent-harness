;;; harness-ui-memory.el --- The memory page and quick capture  -*- lexical-binding: t; -*-

;;; Commentary:

;; The lasting memories (harness-memory.el) on a page of their own:
;; what the agent and the user saved, in the two scopes, grouped by kind,
;; with the buttons that add, edit, forget, search and consolidate them.
;; `C-c h M' opens it; `C-c h m' captures one from anywhere.
;;
;; The page reads, top to bottom (the project is the buffer's, as the
;; settings page's is):
;;
;;   Memory  harness                3 memories · 2 project memories · 1 user memory
;;   Add Search Consolidate Refresh
;;
;;   Project · harness                              Add Consolidate
;;   Preference
;;     • Don't import inside function bodies: put imports at the top.
;;       Preference · Aug 12                        Edit Forget
;;   Fact
;;     • The deploy target is Fly.io.
;;       Fact · Aug 12                              Edit Forget
;;
;;   User                                           Add Consolidate
;;     • Prefer short answers and no filler.
;;       Preference · Aug 12                        Edit Forget
;;
;; Its states say "Loading memories…", "No memories", "No project
;; memories", "No user memories", "No matches for “QUERY”" or "Memory
;; unavailable"; a search in effect says "Matches for “QUERY”" with
;; [Clear].
;;
;; A click or RET on a button does what its key does: a adds to the
;; project, A to the user's memories, e edits the memory at point, d
;; forgets it, / searches, c and C consolidate the project's memories and
;; the user's, g loads the page again, and C-u m captures a user memory
;; rather than the project's.  The page adds the memories the harness
;; announces (`memory/changed'), once for a burst of them, and asks again
;; when the UI connects to a harness again.
;;
;; Nothing here reads the memories directly: the page is a client, and
;; asks `_harness/memory/list', `search', `add', `update', `delete' and
;; `consolidate', so it works the same against a harness server
;; elsewhere.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'text-property-search)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)
(require 'harness-ui)

(defgroup harness-ui-memory nil
  "The memory page." :group 'harness-ui)

(defface harness-memories-title-face '((t :inherit bold :height 1.3))
  "The title of the memory page." :group 'harness-ui-memory)

(defface harness-memories-heading-face '((t :inherit bold :height 1.1))
  "The headings of the memory page." :group 'harness-ui-memory)

(defface harness-memories-scope-face '((t :inherit (font-lock-keyword-face bold)))
  "A scope's heading on the memory page." :group 'harness-ui-memory)

(defface harness-memories-kind-face '((t :inherit shadow))
  "The kind and date of a memory." :group 'harness-ui-memory)

(defface harness-memories-bullet-face '((t :inherit (font-lock-builtin-face bold)))
  "The bullet of a memory." :group 'harness-ui-memory)

(defconst harness-ui-memories--kinds
  '((preference "Preference") (convention "Convention") (fact "Fact") (reference "Reference"))
  "The kinds of memory and how they read on the page, in its order.")

(defconst harness-ui-memories--scopes
  '((project "Project") (user "User"))
  "The scopes of memory and how they read on the page, the narrower first.")

(defvar-local harness-ui-memories--memories nil
  "The memories the page shows, as the harness sent them, newest first.")

(defvar-local harness-ui-memories--project nil
  "The project the page is about, as a directory name.")

(defvar-local harness-ui-memories--cwd nil
  "The directory the page was opened from.")

(defvar-local harness-ui-memories--query nil
  "The search in effect on the page, or nil.")

(defvar-local harness-ui-memories--loading nil
  "Non-nil while the page waits for its first answer.")

(defvar-local harness-ui-memories--error nil
  "Why the page could not read the memories, or nil.")

(defvar-local harness-ui-memories--fetching nil
  "Non-nil while a request for the memories is in flight.")

(defvar-local harness-ui-memories--pending nil
  "Non-nil when another request is wanted once the one in flight comes.")

(defvar-local harness-ui-memories--drawn nil
  "The text the page drew last, without properties, or nil.
A drawing that would show the same text is skipped, so a burst of
changes does not redraw the buffer for nothing.")

;;;; Helpers

(defun harness-ui-memories--name (project)
  "Return the name PROJECT reads as on the page."
  (let ((name (file-name-nondirectory (directory-file-name (or project "")))))
    (if (string-empty-p name) (or project "project") name)))

(defun harness-ui-memories--buffer-name (project)
  "Return the name of the memory page of PROJECT."
  (format "*harness memories: %s*" (harness-ui-memories--name project)))

(defun harness-ui-memories--buffers ()
  "Return the memory pages of this Emacs."
  (cl-remove-if-not (lambda (buffer)
                      (with-current-buffer buffer
                        (derived-mode-p 'harness-ui-memories-mode)))
                    (buffer-list)))

(defun harness-ui-memories--context ()
  "Return (CWD . PROJECT) for a page about the current buffer.
In a chat buffer that is the session's working directory and project."
  (let* ((session (and harness-ui-session-id (harness-ui-session harness-ui-session-id)))
         (cwd (file-name-as-directory
               (expand-file-name (or (plist-get session :cwd) default-directory))))
         (project (or (plist-get session :project)
                      (if (file-remote-p cwd) cwd (harness-files-project-root cwd)))))
    (cons cwd (file-name-as-directory project))))

(defun harness-ui-memories--sym (value)
  "Return VALUE, a symbol or a string, as a symbol, or nil."
  (cond ((and (stringp value) (not (string-empty-p value))) (intern value))
        ((and value (symbolp value) (not (memq value '(t :false :null)))) value)))

(defun harness-ui-memories--read (memory)
  "Return MEMORY, as the harness sent it, with its scope and kind symbols."
  (when (and (plistp memory) (stringp (plist-get memory :id)))
    (let ((scope (harness-ui-memories--sym (plist-get memory :scope)))
          (kind (harness-ui-memories--sym (plist-get memory :kind))))
      (when (and scope kind)
        (append (list :scope scope :kind kind)
                (harness-plist-remove memory :scope :kind))))))

(defun harness-ui-memories--count (n what &optional plural)
  "Return N of WHAT as \"1 memory\" or \"2 memories\".
PLURAL is the plural, WHAT with an s by default."
  (format "%d %s" n (if (= n 1) what (or plural (concat what "s")))))

(defun harness-ui-memories--date (memory)
  "Return when MEMORY was last changed, as the page shows it."
  (let ((time (or (plist-get memory :updated) (plist-get memory :created))))
    (if (numberp time) (format-time-string "%b %-d" time) "—")))

(defun harness-ui-memories--kind-label (kind)
  "Return the label of KIND."
  (or (nth 1 (assq kind harness-ui-memories--kinds)) (format "%s" kind)))

(defun harness-ui-memories--scope-label (scope)
  "Return the label of SCOPE."
  (or (nth 1 (assq scope harness-ui-memories--scopes)) (format "%s" scope)))

(defun harness-ui-memories--kind-headed (kind &optional memories)
  "Return the MEMORIES of KIND, in the order the page shows them.
MEMORIES defaults to every memory the page holds."
  (cl-remove-if-not (lambda (memory) (eq (plist-get memory :kind) kind))
                    (or memories harness-ui-memories--memories)))

(defun harness-ui-memories--scoped (scope)
  "Return the memories of SCOPE on the page, in the order it shows them."
  (cl-remove-if-not (lambda (memory) (eq (plist-get memory :scope) scope))
                    harness-ui-memories--memories))

(defun harness-ui-memories--id-at-point ()
  "Return the id of the memory at point, or nil."
  (or (get-text-property (point) 'harness-ui-memories-id)
      (get-text-property (line-beginning-position) 'harness-ui-memories-id)))

(defun harness-ui-memories--memory-at-point ()
  "Return the memory at point, or signal that there is none."
  (let ((id (harness-ui-memories--id-at-point)))
    (unless id (user-error "No memory here"))
    (or (cl-find id harness-ui-memories--memories
                 :key (lambda (memory) (plist-get memory :id)) :test #'equal)
        (user-error "No memory here"))))

;;;; Drawing

(defun harness-ui-memories--insert-buttons (buttons)
  "Insert BUTTONS, a list of (LABEL ACTION HELP), separated by spaces."
  (let ((first t))
    (dolist (button buttons)
      (unless first (insert " "))
      (setq first nil)
      (harness-ui-button (nth 0 button) (nth 1 button) :help (nth 2 button)))))

(defun harness-ui-memories--insert-memory (memory)
  "Insert MEMORY as the page draws it."
  (let* ((id (plist-get memory :id))
         (text (string-trim (or (plist-get memory :text) "")))
         (start (point))
         (lines (split-string text "\n")))
    (insert "    " (propertize "•" 'face 'harness-memories-bullet-face) " ")
    (insert (car lines))
    (dolist (line (cdr lines))
      (insert "\n      " line))
    (insert "\n      "
            (propertize (format "%s · %s"
                                (harness-ui-memories--kind-label (plist-get memory :kind))
                                (harness-ui-memories--date memory))
                        'face 'harness-memories-kind-face)
            "    ")
    (harness-ui-memories--insert-buttons
     (list (list "Edit" (lambda () (harness-ui-memories-edit id)) "Edit this memory")
           (list "Forget" (lambda () (harness-ui-memories-forget id)) "Forget this memory")))
    (insert "\n")
    ;; The whole row stands for the memory: RET in it edits it.
    (add-text-properties start (point) (list 'harness-ui-memories-id id))))

(defun harness-ui-memories--insert-heading (scope)
  "Insert the heading of SCOPE and its buttons."
  (let ((label (harness-ui-memories--scope-label scope)))
    (insert "  " (propertize (if (eq scope 'project)
                                 (format "%s · %s" label (harness-ui-memories--name harness-ui-memories--project))
                               label)
                             'face 'harness-memories-scope-face)
            "    ")
    (harness-ui-memories--insert-buttons
     (list (list "Add" (lambda () (harness-ui-memories-add scope))
                 (if (eq scope 'project) "New project memory" "New user memory"))
           (list "Consolidate" (lambda () (harness-ui-memories-consolidate scope))
                 (if (eq scope 'project) "Merge duplicate project memories"
                   "Merge duplicate user memories"))))
    (insert "\n")))

(defun harness-ui-memories--insert-scope (scope)
  "Insert SCOPE's section of the page."
  (harness-ui-memories--insert-heading scope)
  (let ((memories (harness-ui-memories--scoped scope)))
    (if (null memories)
        (insert "      " (propertize (if (eq scope 'project) "No project memories" "No user memories")
                                     'face 'harness-memories-kind-face) "\n")
      (dolist (kind (mapcar #'car harness-ui-memories--kinds))
        (let ((of-kind (harness-ui-memories--kind-headed kind memories))
              (first t))
          (dolist (memory of-kind)
            (if first
                (progn
                  (insert "    " (propertize (harness-ui-memories--kind-label kind)
                                             'face 'harness-memories-heading-face) "\n")
                  (setq first nil))
              nil)
            (harness-ui-memories--insert-memory memory)))))
    (insert "\n")))

(defun harness-ui-memories--counts ()
  "Return the line that counts the memories of the page."
  (let* ((all (length harness-ui-memories--memories))
         (project (length (harness-ui-memories--scoped 'project)))
         (user (length (harness-ui-memories--scoped 'user))))
    (if (zerop all)
        "No memories"
      (concat (harness-ui-memories--count all "memory" "memories")
              " · " (harness-ui-memories--count project "project memory" "project memories")
              " · " (harness-ui-memories--count user "user memory" "user memories")))))

(defun harness-ui-memories--draw ()
  "Draw the page from the memories it holds."
  (let ((inhibit-read-only t)
        (project harness-ui-memories--project)
        (here (harness-ui-memories--id-at-point)))
    (erase-buffer)
    (insert " " (propertize "Memory" 'face 'harness-memories-title-face)
            "  " (propertize (harness-ui-memories--name project) 'face 'harness-memories-heading-face)
            "    " (propertize (if harness-ui-memories--error "Memory unavailable"
                                (harness-ui-memories--counts))
                              'face 'harness-memories-kind-face)
            "\n\n")
    (harness-ui-memories--insert-buttons
     (list (list "Add" (lambda () (harness-ui-memories-add 'project)) "New memory")
           (list "Search" #'harness-ui-memories-search "Search memories")
           (list "Consolidate" (lambda () (harness-ui-memories-consolidate 'project))
                 "Merge duplicate project memories")
           (list "Refresh" #'harness-ui-memories-refresh "Load the memories again")))
    (insert "\n")
    (when (and harness-ui-memories--query (not (string-empty-p harness-ui-memories--query)))
      (insert "\n  " (propertize (format "Matches for “%s”" harness-ui-memories--query)
                                 'face 'harness-memories-heading-face)
              "    ")
      (harness-ui-memories--insert-buttons
       (list (list "Clear" #'harness-ui-memories-clear "Clear the search")))
      (insert "\n"))
    (cond
     ((and harness-ui-memories--loading (null harness-ui-memories--memories))
      (insert "\n  " (propertize "Loading memories…" 'face 'harness-memories-kind-face) "\n"))
     (harness-ui-memories--error
      (insert "\n  " (propertize harness-ui-memories--error 'face 'error) "\n  ")
      (harness-ui-memories--insert-buttons
       (list (list "Retry" #'harness-ui-memories-refresh "Load the memories again")))
      (insert "\n"))
     ((and harness-ui-memories--query (null harness-ui-memories--memories))
      (insert "\n  " (propertize (format "No matches for “%s”" harness-ui-memories--query)
                                 'face 'harness-memories-kind-face)
              "\n"))
     ((null harness-ui-memories--memories)
      (insert "\n")
      (harness-ui-memories--insert-scope 'project)
      (harness-ui-memories--insert-scope 'user))
     (t
      (insert "\n")
      (harness-ui-memories--insert-scope 'project)
      (harness-ui-memories--insert-scope 'user)))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (setq harness-ui-memories--drawn text))
    (goto-char (point-min))
    (when here
      (let ((found (text-property-search-forward 'harness-ui-memories-id here #'equal)))
        (when found (goto-char (prop-match-beginning found)))))))

(defun harness-ui-memories--render ()
  "Draw the page."
  (harness-ui-memories--draw))

;;;; Asking the harness

(defun harness-ui-memories--load (&optional buffer)
  "Ask for the memories of BUFFER's page, then draw them.
The query in effect decides between listing and searching.  A request
already in flight makes this one wait for it."
  (let ((buffer (or buffer (current-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (if harness-ui-memories--fetching
            (setq harness-ui-memories--pending t)
          (setq harness-ui-memories--fetching t
                harness-ui-memories--loading (null harness-ui-memories--memories)
                harness-ui-memories--error nil)
          (let* ((query harness-ui-memories--query)
                 (project harness-ui-memories--project)
                 (opts (list :project project :limit 500))
                 (done (lambda (result)
                         (when (buffer-live-p buffer)
                           (with-current-buffer buffer
                             (setq harness-ui-memories--fetching nil
                                   harness-ui-memories--loading nil
                                   harness-ui-memories--error nil
                                   harness-ui-memories--memories
                                   (delq nil (mapcar #'harness-ui-memories--read result)))
                             (harness-ui-memories--render)
                             (when harness-ui-memories--pending
                               (setq harness-ui-memories--pending nil)
                               (harness-ui-memories--load buffer))))))
                 (failed (lambda (err)
                           (when (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (setq harness-ui-memories--fetching nil
                                     harness-ui-memories--loading nil
                                     harness-ui-memories--memories nil
                                     harness-ui-memories--error
                                     (if (harness-ui-connection-replaced-p err)
                                         "Connection replaced"
                                       (harness-error-message err)))
                               (harness-ui-memories--render))))))
            (if (and (stringp query) (not (string-empty-p query)))
                (harness-ui-call "_harness/memory/search"
                                 (list :query query :opts opts) done failed)
              (harness-ui-call "_harness/memory/list"
                               (list :opts opts) done failed))))))))

(defun harness-ui-memories-refresh ()
  "Load the memory page again."
  (interactive)
  (harness-ui-memories--load))

(defun harness-ui-memories--value (label)
  "Return the symbol of the kind or scope whose LABEL is at point."
  (or (car (cl-find label harness-ui-memories--kinds :key #'cadr :test #'equal))
      (car (cl-find label harness-ui-memories--scopes :key #'cadr :test #'equal))))

(defun harness-ui-memories--read-kind (&optional initial)
  "Read a kind of memory, or INITIAL."
  (harness-ui-memories--value
   (completing-read "Kind: " (mapcar #'cadr harness-ui-memories--kinds) nil t
                    (and initial (harness-ui-memories--kind-label initial)))))

;;;; Adding and changing

(defun harness-ui-memories--added (_result)
  "Say that the memory was saved, and draw the page again."
  (message "Memory saved")
  (dolist (page (harness-ui-memories--buffers))
    (with-current-buffer page (harness-ui-memories--load page))))

(defun harness-ui-memories--failed (what)
  "Return a handler saying WHAT failed and why."
  (lambda (err)
    (message "%s · %s" what (harness-error-message err))))

(defun harness-ui-memories-add (scope)
  "Add a memory to SCOPE, project or user."
  (interactive (list 'project))
  (let* ((kind (harness-ui-memories--read-kind 'preference))
         (text (read-string "Memory: "))
         (project (and (eq scope 'project) harness-ui-memories--project))
         (opts (list :kind (symbol-name (or kind 'preference))
                     :scope (symbol-name scope)
                     :project project)))
    (when (and (eq scope 'project) (null project))
      (user-error "No project here"))
    (when (harness-string-blank-p text)
      (user-error "No memory to save"))
    (harness-ui-call "_harness/memory/add"
                     (list :text text :opts opts)
                     #'harness-ui-memories--added
                     (harness-ui-memories--failed "Memory not saved"))))

(defun harness-ui-memories-add-user ()
  "Add a memory to the user's memories."
  (interactive)
  (harness-ui-memories-add 'user))

(defun harness-ui-memories-edit (id)
  "Edit memory ID."
  (interactive (list (plist-get (harness-ui-memories--memory-at-point) :id)))
  (let* ((memory (cl-find id harness-ui-memories--memories
                          :key (lambda (one) (plist-get one :id)) :test #'equal)))
    (unless memory (user-error "No memory here"))
    (let* ((kind (harness-ui-memories--read-kind (plist-get memory :kind)))
           (text (read-string "Memory: " (plist-get memory :text))))
      (when (harness-string-blank-p text)
        (user-error "No memory to save"))
      (harness-ui-call "_harness/memory/update"
                       (list :id id :kind (symbol-name (or kind (plist-get memory :kind)))
                             :text text)
                       (lambda (_result) (message "Memory updated")
                         (harness-ui-memories--load))
                       (harness-ui-memories--failed "Memory not updated")))))

(defun harness-ui-memories-forget (&optional id)
  "Forget memory ID, or the one at point."
  (interactive)
  (let ((id (or id (plist-get (harness-ui-memories--memory-at-point) :id))))
    (unless (and id (y-or-n-p "Forget memory? "))
      (user-error "No memory forgotten"))
    (harness-ui-call "_harness/memory/delete" (list :id id)
                     (lambda (_result) (message "Memory forgotten")
                       (harness-ui-memories--load))
                     (harness-ui-memories--failed "Memory not forgotten"))))

(defun harness-ui-memories-consolidate (scope)
  "Consolidate the memories of SCOPE with a cheap model."
  (interactive (list 'project))
  (let ((project (and (eq scope 'project) harness-ui-memories--project)))
    (when (and (eq scope 'project) (null project))
      (user-error "No project here"))
    (unless (y-or-n-p "Consolidate memories? ")
      (user-error "No consolidation"))
    (message "Consolidating…")
    (harness-ui-call
     "_harness/memory/consolidate"
     (list :opts (list :scope (symbol-name scope)
                       :project project
                       :cwd harness-ui-memories--cwd))
     (lambda (result)
       (message "%s" (if (> (or (plist-get result :changed) 0) 0)
                         (format "%d changed · %d removed"
                                 (or (plist-get result :added-count) 0)
                                 (or (plist-get result :removed-count) 0))
                       "No changes"))
       (harness-ui-memories--load))
     (harness-ui-memories--failed "Consolidation failed"))))

;;;; Searching

(defun harness-ui-memories-search (query)
  "Search the memories for QUERY, or list them all when it is empty."
  (interactive (list (read-string "Search memories: ")))
  (setq harness-ui-memories--query
        (and (stringp query) (not (string-blank-p query)) query))
  (harness-ui-memories--load))

(defun harness-ui-memories-clear ()
  "Clear the search and list every memory again."
  (interactive)
  (setq harness-ui-memories--query nil)
  (harness-ui-memories--load))

;;;; The page

(defvar harness-ui-memories-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "a") (lambda () (interactive) (harness-ui-memories-add 'project)))
    (define-key map (kbd "A") #'harness-ui-memories-add-user)
    (define-key map (kbd "e") (lambda () (interactive)
                                (harness-ui-memories-edit
                                 (plist-get (harness-ui-memories--memory-at-point) :id))))
    (define-key map (kbd "RET") (lambda () (interactive)
                                  (harness-ui-memories-edit
                                   (plist-get (harness-ui-memories--memory-at-point) :id))))
    (define-key map (kbd "d") #'harness-ui-memories-forget)
    (define-key map (kbd "/") #'harness-ui-memories-search)
    (define-key map (kbd "c") (lambda () (interactive) (harness-ui-memories-consolidate 'project)))
    (define-key map (kbd "C") (lambda () (interactive) (harness-ui-memories-consolidate 'user)))
    (define-key map (kbd "g") #'harness-ui-memories-refresh)
    map)
  "Keymap of the memory page.")

(define-derived-mode harness-ui-memories-mode special-mode "Memory"
  "Major mode of the memory page.
Its keys are in `harness-ui-memories-mode-map'; RET and a click edit the
memory at point, as [Edit] does."
  (setq-local revert-buffer-function
              (lambda (&rest _) (harness-ui-memories--load)))
  (setq-local truncate-lines nil)
  (setq-local word-wrap t))

(put 'harness-ui-memories-mode 'harness-menu-group
     '("Memory"
       ["Memory"
        ("RET" "Edit memory" harness-ui-memories-edit)
        ("a" "New project memory" harness-ui-memories-add)
        ("A" "New user memory" harness-ui-memories-add-user)
        ("e" "Edit memory" harness-ui-memories-edit)
        ("d" "Forget memory" harness-ui-memories-forget)
        ("/" "Search memories" harness-ui-memories-search)
        ("g" "Refresh" harness-ui-memories-refresh)]))

;;;###autoload
(defun harness-memories (&optional directory)
  "Show the lasting memories for DIRECTORY's project.
DIRECTORY defaults to the current buffer's directory, or in a chat
buffer to the session's working directory."
  (interactive)
  (let* ((context (if directory
                      (let ((dir (file-name-as-directory (expand-file-name directory))))
                        (cons dir (file-name-as-directory
                                   (if (file-remote-p dir) dir (harness-files-project-root dir)))))
                    (harness-ui-memories--context)))
         (cwd (car context))
         (project (cdr context))
         (buffer (get-buffer-create (harness-ui-memories--buffer-name project))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'harness-ui-memories-mode)
        (harness-ui-memories-mode))
      (setq harness-ui-memories--project project
            harness-ui-memories--cwd cwd
            harness-ui-memories--loading t
            harness-ui-memories--error nil
            harness-ui-memories--query nil
            default-directory cwd)
      (harness-ui-memories--render))
    (harness-ui-display-view buffer)
    (harness-ui-memories--load buffer)
    buffer))

;;;###autoload
(defun harness-remember (text &optional user)
  "Save TEXT as a lasting memory, and say so.
The memory belongs to the project of this buffer, or, with USER true, to
the user's memories in every project.  It is a preference, which the
memory page can change to another kind."
  (interactive (list (read-string "Memory: ") current-prefix-arg))
  (let* ((context (harness-ui-memories--context))
         (project (cdr context))
         (scope (if user 'user 'project))
         (opts (list :kind "preference" :scope (symbol-name scope) :project project)))
    (when (harness-string-blank-p text)
      (user-error "No memory to save"))
    (harness-ui-call "_harness/memory/add"
                     (list :text text :opts opts)
                     (lambda (_result) (message "Memory saved"))
                     (harness-ui-memories--failed "Memory not saved"))))

;;;; Following the harness

(defun harness-ui-memories--reload-soon (buffer)
  "Ask for the memories of BUFFER soon, once for a burst of changes."
  (when (buffer-live-p buffer)
    (harness-debounce (list 'harness-ui-memories-reload buffer) 0.25
                      (lambda (buf)
                        (when (buffer-live-p buf)
                          (with-current-buffer buf (harness-ui-memories--load))))
                      buffer)))

(defun harness-ui-memories--on-event (event _args)
  "Reload the memory pages when the harness says a memory changed."
  (when (equal event "memory/changed")
    (dolist (buffer (harness-ui-memories--buffers))
      (harness-ui-memories--reload-soon buffer))))

(defun harness-ui-memories--redraw-all ()
  "Reload every memory page, after a connection or a reload."
  (dolist (buffer (harness-ui-memories--buffers))
    (harness-ui-memories--reload-soon buffer)))

;;;; Module

(defun harness-ui-memory--init ()
  "Wire the memory page into the UI."
  (add-hook 'harness-ui-event-functions #'harness-ui-memories--on-event)
  (add-hook 'harness-ui-redraw-hook #'harness-ui-memories--redraw-all)
  (define-key harness-ui-map (kbd "M") #'harness-memories)
  (define-key harness-ui-map (kbd "m") #'harness-remember))

(defun harness-ui-memory--shutdown ()
  "Stop following memories, and unbind the page's keys.
A key another module bound in the meantime is left as it is."
  (remove-hook 'harness-ui-event-functions #'harness-ui-memories--on-event)
  (remove-hook 'harness-ui-redraw-hook #'harness-ui-memories--redraw-all)
  (dolist (binding '(("M" . harness-memories)
                     ("m" . harness-remember)))
    (when (eq (lookup-key harness-ui-map (kbd (car binding))) (cdr binding))
      (define-key harness-ui-map (kbd (car binding)) nil))))

(harness-define-module 'ui-memory
  :doc "The memory page and quick capture: lasting memories seen, added, edited, forgotten, searched and consolidated."
  :requires '(ui)
  :init #'harness-ui-memory--init
  :shutdown #'harness-ui-memory--shutdown)

(provide 'harness-ui-memory)
;;; harness-ui-memory.el ends here
