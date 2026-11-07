;;; harness-ui-memory-test.el --- Tests for the memory page  -*- lexical-binding: t; -*-

;;; Commentary:

;; The memory page over the in-process harness: the two scopes, each
;; memory under its kind, the counts, the buttons and their tooltips,
;; and the exact text of every state (loading, no memories, no matches,
;; unavailable).  The commands add from the page and from anywhere
;; (`harness-remember'), edit, forget, search and clear, and the page
;; follows `memory/changed' by itself.  A test that only looked for a
;; word could pass on the wrong scope's heading, so the rendered text is
;; checked.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-acp-token)
(defvar harness-acp--server-enabled)
(defvar harness-menu)
(defvar harness-tools-menu)
(defvar harness-ui-map)
(defvar harness-ui--sessions)
(defvar harness-ui-memories--memories)
(defvar harness-ui-memories--project)
(defvar harness-ui-memories--cwd)
(defvar harness-ui-memories--query)
(defvar harness-ui-memories--loading)
(defvar harness-ui-memories--error)
(defvar harness-ui-memories--fetching)
(defvar harness-ui-memories--drawn)

(declare-function harness-memories "harness-ui-memory" (&optional directory))
(declare-function harness-remember "harness-ui-memory" (text &optional user))
(declare-function harness-ui-memories-add "harness-ui-memory" (scope))
(declare-function harness-ui-memories-add-user "harness-ui-memory" ())
(declare-function harness-ui-memories-edit "harness-ui-memory" (id))
(declare-function harness-ui-memories-forget "harness-ui-memory" (&optional id))
(declare-function harness-ui-memories-search "harness-ui-memory" (query))
(declare-function harness-ui-memories-clear "harness-ui-memory" ())
(declare-function harness-ui-memories-consolidate "harness-ui-memory" (scope))
(declare-function harness-ui-memories--load "harness-ui-memory" (&optional buffer))
(declare-function harness-ui-memories--draw "harness-ui-memory" ())
(declare-function harness-ui-memories--buffers "harness-ui-memory" ())
(declare-function harness-ui-memories--name "harness-ui-memory" (project))

(defvar harness-ui-memory-test--dir nil
  "The project a test adds its memories to; its body's `dir'.")

(defmacro harness-ui-memory-test-with (&rest body)
  "Run BODY with the memory module and the UI, connected in process.
The state directory is fresh, the project is `dir', and the page is on
the bus, so the tests use the names the real harness answers to."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (setq harness-acp--clients nil)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config tools memory acp))
         (harness-test-load-module m)))
     (setq harness-ui-memory-test--dir dir)
     (let ((harness-acp-token nil)
           (default-directory harness-ui-memory-test--dir))
       ;; The UI's session list is not what these tests are about, and
       ;; the sessions module is not loaded: keep its first fetch quiet.
       (harness-register-method 'session/list (lambda (&optional _opts) nil))
       (harness-test-load-module 'ui)
       (harness-test-load-module 'ui-memory)
       (unwind-protect
           (progn ,@body)
         (dolist (buffer (harness-ui-memories--buffers))
           (when (buffer-live-p buffer) (kill-buffer buffer)))
         (dolist (client (copy-sequence harness-acp--clients))
           (harness-acp--drop-client client))))))

(defun harness-ui-memory-test-add (text &rest opts)
  "Add TEXT as a memory of the project `dir' with OPTS; return it."
  (harness-call 'memory/add text (append (list :project harness-ui-memory-test--dir) opts)))

(defun harness-ui-memory-test--text (buffer)
  "Return the text BUFFER shows, without properties."
  (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-memory-test--wait (buffer)
  "Wait until BUFFER's page has an answer, and return BUFFER."
  (harness-test-wait
   (lambda ()
     (with-current-buffer buffer
       (and (not harness-ui-memories--fetching)
            (not harness-ui-memories--loading)
            harness-ui-memories--drawn)))
   5 "the memory page")
  buffer)

(defun harness-ui-memory-test--page (&optional query)
  "Open the page of `dir', search QUERY when given, and wait for it."
  (let ((buffer (harness-memories harness-ui-memory-test--dir)))
    (harness-ui-memory-test--wait buffer)
    (when query
      (with-current-buffer buffer (harness-ui-memories-search query))
      (harness-test-wait
       (lambda ()
         (with-current-buffer buffer
           (and (not harness-ui-memories--fetching)
                (equal query harness-ui-memories--query)
                (string-search (format "Matches for “%s”" query)
                               (harness-ui-memory-test--text buffer)))))
       5 "the search"))
    buffer))

(defun harness-ui-memory-test--buttons ()
  "Return the page's buttons at point, each (LABEL HELP)."
  (let ((pos (point-min)) found)
    (while (setq pos (next-button pos))
      (let ((button (button-at pos)))
        (when button
          (push (list (button-label button) (button-get button 'help-echo)) found)))
      (setq pos (1+ pos)))
    (nreverse found)))

(defun harness-ui-memory-test--button (label)
  "Return the help of the page's button LABEL, or \\='missing."
  (or (cadr (cl-find label (harness-ui-memory-test--buttons)
                     :key #'car :test #'equal))
      'missing))

(defun harness-ui-memory-test--line-with (buffer text)
  "Return the line of BUFFER's page that holds TEXT, or nil."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (when (search-forward text nil t)
        (buffer-substring-no-properties (line-beginning-position) (line-end-position))))))

(ert-deftest harness-ui-memories-shows-scopes-kinds-counts-and-buttons ()
  "The page names its project, counts both scopes and draws each memory
under its scope and kind -- the project's under Project, the user's
under User -- with the buttons and tooltips it offers."
  (harness-ui-memory-test-with
    (let* ((convention (harness-ui-memory-test-add "Don't import inside function bodies."
                                                   :kind "convention" :scope "project"))
           (fact (harness-ui-memory-test-add "The deploy target is Fly.io."
                                             :kind "fact" :scope "project"))
           (preference (harness-ui-memory-test-add "Prefer short answers and no filler."
                                                   :kind "preference" :scope "user"))
           (name (harness-ui-memories--name harness-ui-memory-test--dir))
           (buffer (harness-ui-memory-test--page))
           (text (harness-ui-memory-test--text buffer)))
      (ignore convention fact preference)
      ;; The header: the page's name, the project, and the counts.
      (should (string-prefix-p
               (format " Memory  %s    3 memories · 2 project memories · 1 user memory\n\n"
                       name)
               text))
      (should (string-search "Add Search Consolidate Refresh\n" text))
      ;; Project first, then the user's.
      (should (string-search (format "  Project · %s    Add Consolidate\n" name) text))
      (should (string-search "  User    Add Consolidate\n" text))
      ;; Each kind heads its memories, and the scope decides where a
      ;; memory goes: the project's preference would belong under User
      ;; if the page forgot the scope.
      (should (string-search "    Convention\n" text))
      (should (string-search "    Fact\n" text))
      (should (string-search "    Preference\n" text))
      (should (string-search "    • Don't import inside function bodies.\n" text))
      (should (string-search "    • The deploy target is Fly.io.\n" text))
      (should (string-search "    • Prefer short answers and no filler.\n" text))
      (let ((project (string-search "  Project ·" text))
            (project-note (string-search "The deploy target" text))
            (user (string-search "  User" text))
            (user-note (string-search "Prefer short answers" text)))
        (should (< project project-note user))
        (should (< user user-note)))
      ;; The kind and date line under each memory.
      (should (harness-ui-memory-test--line-with buffer "Convention · "))
      (should (harness-ui-memory-test--line-with buffer "Fact · "))
      (should (harness-ui-memory-test--line-with buffer "Preference · "))
      ;; Buttons, with their tooltips.
      (should (equal "New memory" (harness-ui-memory-test--button "Add")))
      (should (equal "Search memories" (harness-ui-memory-test--button "Search")))
      (should (equal "Merge duplicate project memories"
                     (harness-ui-memory-test--button "Consolidate")))
      (should (equal "Load the memories again"
                     (harness-ui-memory-test--button "Refresh")))
      (should (equal "Edit this memory" (harness-ui-memory-test--button "Edit")))
      (should (equal "Forget this memory" (harness-ui-memory-test--button "Forget")))
      ;; The page's keys, and the keys that open it and capture a memory.
      (with-current-buffer buffer
        (should (commandp (key-binding (kbd "a"))))
        (should (eq (key-binding (kbd "A")) 'harness-ui-memories-add-user))
        (should (commandp (key-binding (kbd "e"))))
        (should (commandp (key-binding (kbd "RET"))))
        (should (eq (key-binding (kbd "d")) 'harness-ui-memories-forget))
        (should (eq (key-binding (kbd "/")) 'harness-ui-memories-search))
        (should (commandp (key-binding (kbd "c"))))
        (should (commandp (key-binding (kbd "C"))))
        (should (eq (key-binding (kbd "g")) 'harness-ui-memories-refresh)))
      (should (eq (lookup-key harness-ui-map (kbd "m")) 'harness-remember))
      (should (eq (lookup-key harness-ui-map (kbd "M")) 'harness-memories)))))

(ert-deftest harness-ui-memories-states-are-noun-phrases ()
  "Every state of the page reads as a noun phrase: the empty scopes, a
search with and without matches, the loading line and the failure."
  (harness-ui-memory-test-with
    ;; Empty: both scopes say so, and the count is No memories.
    (let* ((buffer (harness-ui-memory-test--page))
           (text (harness-ui-memory-test--text buffer)))
      (should (string-search "No memories\n" text))
      (should (string-search "  Project ·" text))
      (should (string-search "No project memories" text))
      (should (string-search "No user memories" text))
      (should-not (string-search "No matches" text)))
    ;; A search that found nothing says so, with the query and [Clear].
    (let* ((buffer (harness-ui-memory-test--page "zeppelin"))
           (text (harness-ui-memory-test--text buffer)))
      (should (string-search "  Matches for “zeppelin”    Clear\n" text))
      (should (string-search "  No matches for “zeppelin”\n" text))
      (should (equal "Clear the search" (harness-ui-memory-test--button "Clear"))))
    ;; While the first answer is out, the page says it is loading.
    (let ((buffer (generate-new-buffer " *harness memory loading*")))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (harness-ui-memories-mode)
              (setq-local harness-ui-memories--project harness-ui-memory-test--dir
                          harness-ui-memories--cwd harness-ui-memory-test--dir
                          harness-ui-memories--loading t
                          harness-ui-memories--fetching t
                          harness-ui-memories--memories nil
                          harness-ui-memories--error nil
                          harness-ui-memories--query nil)
              (harness-ui-memories--draw))
            (should (string-search "  Loading memories…\n"
                                   (harness-ui-memory-test--text buffer))))
        (kill-buffer buffer)))
    ;; A failure says the page is unavailable, why, and offers Retry.
    (let ((buffer (generate-new-buffer " *harness memory error*")))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (harness-ui-memories-mode)
              (setq-local harness-ui-memories--project harness-ui-memory-test--dir
                          harness-ui-memories--cwd harness-ui-memory-test--dir
                          harness-ui-memories--loading nil
                          harness-ui-memories--fetching nil
                          harness-ui-memories--memories nil
                          harness-ui-memories--error "Connection closed"
                          harness-ui-memories--query nil)
              (harness-ui-memories--draw)
              (let ((text (harness-ui-memory-test--text buffer)))
                (should (string-search "Memory unavailable" text))
                (should (string-search "Connection closed" text))
                (should (equal "Load the memories again"
                               (harness-ui-memory-test--button "Retry")))))
        (kill-buffer buffer))))))

(ert-deftest harness-ui-memories-remembers-edits-and-forgets ()
  "`harness-remember' saves a project preference from anywhere, and a
user one with a prefix; the page follows both without being asked, and
its Edit and Forget commands change the store the page then shows."
  (harness-ui-memory-test-with
    (let* ((buffer (harness-ui-memory-test--page))
           (text (lambda () (harness-ui-memory-test--text buffer))))
      ;; A project memory from a plain buffer, as C-c h m captures one.
      (with-temp-buffer
        (setq default-directory harness-ui-memory-test--dir)
        (harness-remember "Don't import inside function bodies."))
      (harness-test-wait (lambda () (string-search "Don't import inside function bodies."
                                                   (funcall text)))
                         5 "the captured memory")
      (should (string-search "1 memory · 1 project memory · 0 user memories" (funcall text)))
      ;; A user memory with the prefix argument.
      (with-temp-buffer
        (setq default-directory harness-ui-memory-test--dir)
        (harness-remember "Prefer short answers." t))
      (harness-test-wait (lambda () (string-search "Prefer short answers." (funcall text)))
                         5 "the user memory")
      (should (string-search "2 memories · 1 project memory · 1 user memory" (funcall text)))
      ;; Edit the project memory: the kind and text the page asks for.
      (let* ((project-memory (cl-find "project" harness-ui-memories--memories
                                      :key (lambda (m) (plist-get m :scope)) :test #'string=))
             (id (plist-get project-memory :id)))
        (should id)
        (with-current-buffer buffer
          (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Convention"))
                    ((symbol-function 'read-string) (lambda (&rest _) "Put imports at the top.")))
            (harness-ui-memories-edit id)))
        (harness-test-wait (lambda () (string-search "Put imports at the top." (funcall text)))
                           5 "the edit")
        (should-not (string-search "Don't import inside function bodies." (funcall text)))
        (should (string-search "Convention · " (funcall text))))
      ;; Forget it: the confirmation is answered, and the page follows.
      (let ((id (plist-get (cl-find "project" harness-ui-memories--memories
                                    :key (lambda (m) (plist-get m :scope)) :test #'string=)
                           :id)))
        (with-current-buffer buffer
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
            (harness-ui-memories-forget id)))
        (harness-test-wait (lambda () (string-search "1 memory · 0 project memories · 1 user memory"
                                                     (funcall text)))
                           5 "the deletion")
        (should (string-search "No project memories" (funcall text)))
        (should (string-search "Prefer short answers." (funcall text)))))))

(ert-deftest harness-ui-memories-searches-and-clears ()
  "A search shows only its matches, with the line that says the query and
[Clear]; clearing it lists every memory again."
  (harness-ui-memory-test-with
    (harness-ui-memory-test-add "The deploy target is Fly.io." :kind "fact")
    (harness-ui-memory-test-add "Don't import inside function bodies." :kind "convention")
    (let* ((buffer (harness-ui-memory-test--page "deploy"))
           (text (harness-ui-memory-test--text buffer)))
      (should (string-search "  Matches for “deploy”    Clear\n" text))
      (should (string-search "The deploy target is Fly.io." text))
      (should-not (string-search "Don't import" text))
      (should (string-search "1 memory · 1 project memory · 0 user memories" text))
      (with-current-buffer buffer (harness-ui-memories-clear))
      (harness-test-wait (lambda () (with-current-buffer buffer
                                      (and (not harness-ui-memories--query)
                                           (not harness-ui-memories--fetching)
                                           (string-search "Don't import"
                                                          (harness-ui-memory-test--text buffer)))))
                         5 "the cleared page")
      (should-not (string-search "Matches for" (harness-ui-memory-test--text buffer)))
      (should (string-search "The deploy target is Fly.io."
                             (harness-ui-memory-test--text buffer))))))

(ert-deftest harness-ui-memories-add-from-the-page ()
  "The page's own Add buttons read a kind and a text and save the memory
in the scope whose heading they are under, with the preferences first."
  (harness-ui-memory-test-with
    (let ((buffer (harness-ui-memory-test--page)))
      (with-current-buffer buffer
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Fact"))
                  ((symbol-function 'read-string) (lambda (&rest _) "The deploy target is Fly.io.")))
          (harness-ui-memories-add 'project)))
      (harness-test-wait
       (lambda () (string-search "The deploy target is Fly.io."
                                 (harness-ui-memory-test--text buffer)))
       5 "the project memory")
      (should (string-search "Fact" (harness-ui-memory-test--text buffer)))
      (should (equal 'project (plist-get (car (harness-call 'memory/list (list :project harness-ui-memory-test--dir :scope "project")))
                                         :scope)))
      ;; The scope heading's button saves the user's.
      (with-current-buffer buffer
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Preference"))
                  ((symbol-function 'read-string) (lambda (&rest _) "Prefer short answers.")))
          (harness-ui-memories-add 'user)))
      (harness-test-wait
       (lambda () (string-search "Prefer short answers."
                                 (harness-ui-memory-test--text buffer)))
       5 "the user memory")
      (should (string-search "2 memories · 1 project memory · 1 user memory"
                             (harness-ui-memory-test--text buffer))))))

(provide 'harness-ui-memory-test)
;;; harness-ui-memory-test.el ends here
