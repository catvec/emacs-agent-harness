;;; harness-ui-quick-search-test.el --- Tests for the quick search  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives the quick search against the real state layer, the in-process
;; ACP connection and the demo provider: where a search comes from and
;; what it favours, the catalogue of commands it sends along, the
;; popout's box and its keys, what an answer shows and what its buttons
;; do.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--loaded)
(defvar harness-tasks--dirty)
(defvar harness-tasks-max-running)
(defvar harness-tasks-require-verification)
(defvar harness-tasks-permission-mode)
(defvar harness-tasks-non-interactive)
(defvar harness-tasks-model)
(defvar harness-tasks-worktrees)
(defvar harness-tasks-search-model)
(defvar harness-tasks-search--warm)
(defvar harness-ui-default-position)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui--sessions)
(defvar harness-ui-map)
(defvar harness-ui-session-id)
(defvar harness-ui-tasks--loading)
(defvar harness-ui-tasks--dir)
(defvar harness-compose-end)
(defvar harness-quick-search-history)
(defvar harness-quick-search-box-mode)
(defvar harness-quick-search--state)
(defvar harness-quick-search--context)
(defvar harness-quick-search--seq)
(defvar harness-quick-search--origin)
(declare-function harness-acp--drop-client "harness-acp")
(declare-function harness-tasks--forget-stores "harness-tasks")
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-chat-mode "harness-ui-chat")
(declare-function harness-ui-popout-buffer "harness-ui-popout")
(declare-function harness-ui-popout-submit "harness-ui-popout")
(declare-function harness-ui-popout-close "harness-ui-popout")
(declare-function harness-compose-text "harness-ui-compose")
(declare-function harness-compose-in-p "harness-ui-compose")
(declare-function harness-quick-search "harness-ui-quick-search")
(declare-function harness-quick-search-context "harness-ui-quick-search")
(declare-function harness-quick-search-bias "harness-ui-quick-search")
(declare-function harness-quick-search-commands "harness-ui-quick-search")
(declare-function harness-quick-search-box-previous "harness-ui-quick-search")
(declare-function harness-quick-search-box-next "harness-ui-quick-search")
(declare-function harness-quick-search-run-command "harness-ui-quick-search")
(declare-function harness-compose-set "harness-ui-compose")
(declare-function harness-quick-search--arrived "harness-ui-quick-search")
(declare-function harness-quick-search--menu-command "harness-ui-quick-search")
(declare-function harness-quick-search--task-target "harness-ui-quick-search")
(declare-function transient-get-suffix "transient")

;;;; A harmless command, and a mode that binds it

(defvar harness-ui-quick-search-test--ran nil
  "The buffer `harness-quick-search-test-run' last ran in.")

(defun harness-quick-search-test-run ()
  "Note the buffer this runs in: a harmless command for a search to run."
  (interactive)
  (setq harness-ui-quick-search-test--ran (current-buffer)))

(defun harness-quick-search-test-old ()
  "An obsolete command, which a search never names."
  (interactive))
(make-obsolete 'harness-quick-search-test-old 'harness-quick-search-test-run "0.1")

(defun harness-quick-search-test--hidden ()
  "An internal command, which a search never names."
  (interactive))

(defvar harness-quick-search-test-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c z") #'harness-quick-search-test-run)
    map)
  "Keys of `harness-quick-search-test-mode'.")

(define-derived-mode harness-quick-search-test-mode special-mode "QS test"
  "A mode whose buffers bind the test command, as a search's origin.")

;;;; The model

(defconst harness-ui-quick-search-test--work
  '((:type text :delta "Working on it.") (:type done :stop-reason end-turn))
  "What a task's session answers.")

(defvar harness-ui-quick-search-test--replies nil
  "What the search model answers next: strings, in turn.
The last one answers every request after it.")

(defvar harness-ui-quick-search-test--requests nil
  "The requests the search model got, newest first.")

(defun harness-ui-quick-search-test--search-p (request)
  "Non-nil when REQUEST is a search's."
  (string-prefix-p "You are the search box" (or (plist-get request :system) "")))

(defun harness-ui-quick-search-test--script (request)
  "Answer REQUEST for the demo provider: a search from the replies, else work."
  (if (harness-ui-quick-search-test--search-p request)
      (let ((reply (if (cdr harness-ui-quick-search-test--replies)
                       (pop harness-ui-quick-search-test--replies)
                     (car harness-ui-quick-search-test--replies))))
        (push request harness-ui-quick-search-test--requests)
        `((:type text :delta ,reply)
          (:type usage :input 1200 :output 40 :cache-read 300 :cost 0.0015)
          (:type done :stop-reason end-turn)))
    harness-ui-quick-search-test--work))

(defmacro harness-ui-quick-search-test-with (&rest body)
  "Load the state layer, the UI and the quick search with the demo provider.
The chat and the task board load too, for their modes.  Run BODY with
one window, closing every popout and board after."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent priority tasks
                          tasks-search acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (clrhash harness-tasks-search--warm)
     (harness-tasks--forget-stores)
     (setq harness-tasks--loaded t
           harness-tasks--dirty nil
           harness-acp--clients nil
           harness-ui-quick-search-test--replies '("{\"show\":[],\"do\":[]}")
           harness-ui-quick-search-test--requests nil
           harness-ui-quick-search-test--ran nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override #'harness-ui-quick-search-test--script)
           (harness-naming-auto nil)
           (harness-tasks-max-running nil)
           (harness-tasks-require-verification nil)
           (harness-tasks-permission-mode 'auto)
           (harness-tasks-non-interactive t)
           (harness-tasks-worktrees nil)
           (harness-tasks-model "demo:scripted")
           (harness-tasks-search-model 'auto)
           (harness-ui-default-position 'full)
           (harness-acp-token nil)
           (harness-quick-search-history nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ;; The UI modules load once the client list is clear, so their
       ;; connection is the one the harness events reach.
       (dolist (m '(ui ui-compose ui-popout ui-chat ui-tasks ui-quick-search))
         (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (unwind-protect
           (save-window-excursion
             (delete-other-windows)
             ,@body)
         ;; Dropping what its box holds: the next test's box starts empty.
         (harness-ui-popout-close '(quick-search) t)
         (dolist (b (buffer-list))
           (when (memq (buffer-local-value 'major-mode b)
                       '(harness-ui-popout-mode harness-ui-tasks-mode harness-quick-search-test-mode))
             (kill-buffer b)))
         (dolist (task (harness-call 'task/list))
           (ignore-errors (harness-call 'task/cancel (plist-get task :id))))
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

;;;; Helpers

(defun harness-ui-quick-search-test--origin (&optional name)
  "Show a buffer NAME in the test mode in the selected window; return it."
  (let ((buffer (get-buffer-create (or name "*quick search origin*"))))
    (with-current-buffer buffer (harness-quick-search-test-mode))
    (switch-to-buffer buffer)
    buffer))

(defun harness-ui-quick-search-test--popout ()
  "The quick search's popout buffer, or nil."
  (harness-ui-popout-buffer '(quick-search)))

(defun harness-ui-quick-search-test--state ()
  "The search the popout shows."
  (buffer-local-value 'harness-quick-search--state (harness-ui-quick-search-test--popout)))

(defun harness-ui-quick-search-test--wait-status (status)
  "Wait until the popout's search has STATUS."
  (harness-test-wait (lambda () (and (harness-ui-quick-search-test--popout)
                                     (eq status (plist-get (harness-ui-quick-search-test--state) :status))))
                     5 (format "the search to be %s" status)))

(defun harness-ui-quick-search-test--text ()
  "The popout's text, without properties."
  (with-current-buffer (harness-ui-quick-search-test--popout)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-quick-search-test--ask (origin query &rest replies)
  "Search QUERY from ORIGIN, the model answering REPLIES; wait for the answer."
  (setq harness-ui-quick-search-test--replies replies
        harness-ui-quick-search-test--requests nil)
  (with-current-buffer origin (harness-quick-search query))
  (harness-ui-quick-search-test--wait-status 'done))

(defun harness-ui-quick-search-test--push (label)
  "Push the button LABEL of the popout."
  (with-current-buffer (harness-ui-quick-search-test--popout)
    (goto-char (point-min))
    (should (search-forward label nil t))
    (push-button (match-beginning 0))))

(defun harness-ui-quick-search-test--first-text ()
  "The text of the first message the model got in the last search."
  (let* ((request (car (last harness-ui-quick-search-test--requests)))
         (first (car (plist-get request :messages))))
    (mapconcat (lambda (block) (or (plist-get block :text) "")) (plist-get first :content) "")))

(defun harness-ui-quick-search-test--pause (seconds)
  "Spin the event loop for SECONDS."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.02))))

(defun harness-ui-quick-search-test--entry (name catalogue)
  "The entry of command NAME in CATALOGUE."
  (cl-find name catalogue :key (lambda (entry) (plist-get entry :command)) :test #'equal))

;;;; Where a search comes from

(ert-deftest harness-ui-quick-search-context-and-bias ()
  "A plain buffer and a chat favour commands; a board favours tasks."
  (harness-ui-quick-search-test-with
    (with-temp-buffer
      (rename-buffer "notes about the docs" t)
      (text-mode)
      (let ((context (harness-quick-search-context)))
        (should (equal "buffer" (plist-get context :view)))
        (should (equal (buffer-name) (plist-get context :title)))
        (should (equal "text-mode" (plist-get context :mode)))
        (should-not (plist-get context :session))
        (should (equal (expand-file-name dir) (plist-get context :project)))
        (should (equal "commands" (harness-quick-search-bias context)))))
    (with-temp-buffer
      (harness-chat-mode)
      (setq harness-ui-session-id "s-quick-1")
      (puthash "s-quick-1" (list :id "s-quick-1" :name "Fix the login bug" :project "/tmp/quick-project/")
               harness-ui--sessions)
      (let ((context (harness-quick-search-context)))
        (should (equal "chat" (plist-get context :view)))
        (should (equal "Fix the login bug" (plist-get context :title)))
        (should (equal "s-quick-1" (plist-get context :session)))
        (should (equal "/tmp/quick-project/" (plist-get context :project)))
        (should (equal "commands" (harness-quick-search-bias context)))))
    (let ((board (harness-tasks dir)))
      (harness-test-wait (lambda () (not (buffer-local-value 'harness-ui-tasks--loading board))) 5 "the board")
      (let ((context (harness-quick-search-context board)))
        (should (equal "board" (plist-get context :view)))
        (should (equal (file-name-nondirectory (directory-file-name dir)) (plist-get context :title)))
        (should (equal (buffer-local-value 'harness-ui-tasks--dir board) (plist-get context :project)))
        (should (equal "tasks" (harness-quick-search-bias context))))
      ;; On a board, C-c h / is the board's own search.
      (let (asked)
        (cl-letf (((symbol-function 'harness-tasks-search) (lambda (&optional query) (push query asked))))
          (with-current-buffer board (harness-quick-search "the flaky test")))
        (should (equal '("the flaky test") asked))
        (should-not (harness-ui-quick-search-test--popout))))
    (should (equal "sessions" (harness-quick-search-bias '(:view "sessions"))))
    (should (equal "sessions" (harness-quick-search-bias '(:view "tree"))))
    (should (equal "commands" (harness-quick-search-bias '(:view "settings"))))))

;;;; The commands

(ert-deftest harness-ui-quick-search-catalogue ()
  "The catalogue has the menu's, the prefix's and the modes' commands, and says where they run."
  (harness-ui-quick-search-test-with
    (let ((chat (with-temp-buffer (harness-chat-mode) (harness-quick-search-commands)))
          (plain (with-temp-buffer (text-mode) (harness-quick-search-commands)))
          (origin (with-current-buffer (harness-ui-quick-search-test--origin)
                    (harness-quick-search-commands))))
      ;; The chat lists the attaching command for the menu.
      (let ((attach (harness-ui-quick-search-test--entry "harness-compose-add-attachment" chat))
            (elsewhere (harness-ui-quick-search-test--entry "harness-compose-add-attachment" plain)))
        (should (equal "Attach file" (plist-get attach :label)))
        (should (equal "Chat" (plist-get attach :where)))
        (should (equal "C-c C-a" (plist-get attach :keys)))
        (should (eq t (plist-get attach :here)))
        ;; Elsewhere it is there too, but does not run there.
        (should (equal "Attach file" (plist-get elsewhere :label)))
        (should (eq :false (plist-get elsewhere :here))))
      ;; A command under the prefix, from anywhere.
      (let ((model (harness-ui-quick-search-test--entry "harness-set-model" plain)))
        (should (string-prefix-p "C-c h " (plist-get model :keys)))
        (should (eq t (plist-get model :here)))
        (should (plist-get model :doc)))
      ;; The quick search itself, in the menu and under the prefix.
      (let ((search (harness-ui-quick-search-test--entry "harness-quick-search" plain)))
        (should (equal "Quick search" (plist-get search :label)))
        (should (equal "C-c h /" (plist-get search :keys))))
      ;; Any other harness command, running where a key binds it.
      (let ((here (harness-ui-quick-search-test--entry "harness-quick-search-test-run" origin))
            (there (harness-ui-quick-search-test--entry "harness-quick-search-test-run" plain)))
        (should (equal "C-c z" (plist-get here :keys)))
        (should (eq t (plist-get here :here)))
        (should (equal "Note the buffer this runs in: a harmless command for a search to run."
                       (plist-get there :doc)))
        (should-not (plist-get there :keys))
        (should (eq :false (plist-get there :here))))
      ;; Never an obsolete or internal command, nor a major mode.
      (dolist (name '("harness-quick-search-test-old" "harness-quick-search-test--hidden"
                      "harness-quick-search-test-mode" "harness-chat-mode"))
        (should-not (harness-ui-quick-search-test--entry name plain)))
      ;; Every entry has the same fields: strings or nil, but :here.
      (dolist (entry plain)
        (should (equal '(:command :keys :where :label :doc :here)
                       (cl-loop for (k _) on entry by #'cddr collect k)))
        (should (stringp (plist-get entry :command)))
        (should (memq (plist-get entry :here) '(t :false)))
        (dolist (key '(:keys :where :label :doc))
          (let ((value (plist-get entry key)))
            (should (or (null value) (and (stringp value) (null (text-properties-at 0 value)))))))))
    ;; C-c h / and the menu's / are the quick search.
    (should (eq 'harness-quick-search (lookup-key harness-ui-map (kbd "/"))))
    (should (eq 'harness-quick-search (harness-quick-search--menu-command)))))

;;;; The box

(ert-deftest harness-ui-quick-search-ret-searches ()
  "RET in the popout's box searches, without the minibuffer, and the line stays."
  (harness-ui-quick-search-test-with
    (setq harness-ui-quick-search-test--replies '("{\"commands\":[\"harness-quick-search-test-run\"]}"))
    (let ((origin (harness-ui-quick-search-test--origin)))
      (with-current-buffer origin (harness-quick-search))
      (let ((popout (harness-ui-quick-search-test--popout)))
        (should popout)
        (should (eq popout (window-buffer (selected-window))))
        (with-current-buffer popout
          (should harness-quick-search-box-mode)
          (should (eq origin harness-quick-search--origin))
          (should (harness-compose-in-p))
          (should (string-match-p "From “\\*quick search origin\\*” (harness-quick-search-test-mode) · favours commands, then sessions"
                                  (harness-ui-quick-search-test--text)))
          (should (string-match-p "RET searches" (harness-ui-quick-search-test--text)))
          (insert "run the test command")
          (should (eq 'harness-quick-search-box-submit (key-binding (kbd "RET"))))
          (cl-letf (((symbol-function 'read-from-minibuffer)
                     (lambda (&rest _) (error "The minibuffer was used")))
                    ((symbol-function 'read-string)
                     (lambda (&rest _) (error "The minibuffer was used"))))
            (call-interactively (key-binding (kbd "RET")))))
        (harness-ui-quick-search-test--wait-status 'done)
        (with-current-buffer popout
          (should (equal "run the test command" (harness-compose-text))))
        (should (equal '("run the test command") harness-quick-search-history))
        (let ((first (harness-ui-quick-search-test--first-text)))
          (should (string-match-p "Context:" first))
          (should (string-match-p "Favour commands" first))
          (should (string-match-p "run the test command" first)))
        (should (string-match-p "harness-quick-search-test-run" (harness-ui-quick-search-test--text)))
        ;; C-c C-c sends it too, and the line stays.
        (setq harness-ui-quick-search-test--requests nil)
        (with-current-buffer popout
          (goto-char harness-compose-end)
          (insert " again")
          (harness-ui-popout-submit)
          (should (equal "run the test command again" (harness-compose-text))))
        (harness-test-wait (lambda () harness-ui-quick-search-test--requests) 5 "the second search")
        (harness-ui-quick-search-test--wait-status 'done)
        (should (equal "run the test command again" (plist-get (harness-ui-quick-search-test--state) :query)))
        ;; Outside the box RET is the content's.
        (with-current-buffer popout
          (goto-char (point-min))
          (should-not (eq 'harness-quick-search-box-submit (key-binding (kbd "RET")))))))))

(ert-deftest harness-ui-quick-search-history-keys ()
  "The box's history keys bring back earlier searches."
  (harness-ui-quick-search-test-with
    (setq harness-quick-search-history (list "newest search" "older search"))
    (with-current-buffer (harness-ui-quick-search-test--origin) (harness-quick-search))
    (with-current-buffer (harness-ui-quick-search-test--popout)
      (insert "typed")
      (should (eq 'harness-quick-search-box-previous (key-binding (kbd "M-p"))))
      (should (eq 'harness-quick-search-box-next (key-binding (kbd "M-n"))))
      (call-interactively (key-binding (kbd "M-p")))
      (should (equal "newest search" (harness-compose-text)))
      (should (harness-compose-in-p))
      (call-interactively (key-binding (kbd "M-p")))
      (should (equal "older search" (harness-compose-text)))
      (should-error (harness-quick-search-box-previous) :type 'user-error)
      (call-interactively (key-binding (kbd "M-n")))
      (should (equal "newest search" (harness-compose-text)))
      (call-interactively (key-binding (kbd "M-n")))
      (should (equal "typed" (harness-compose-text)))
      (should-error (harness-quick-search-box-next) :type 'user-error)
      ;; An entry the box holds already is skipped.
      (harness-compose-set "newest search")
      (harness-quick-search-box-previous)
      (should (equal "older search" (harness-compose-text)))
      ;; Outside the box the keys are the buffer's.
      (goto-char (point-min))
      (should-not (eq 'harness-quick-search-box-previous (key-binding (kbd "M-p")))))))

;;;; What an answer shows

(ert-deftest harness-ui-quick-search-shows-the-answer ()
  "An answer shows its commands, sessions and tasks, each with its buttons; [Open] opens."
  (harness-ui-quick-search-test-with
    (let* ((task (plist-get (harness-call 'task/submit default-directory "Write the docs") :id))
           (session (plist-get (harness-call 'session/create :cwd default-directory
                                             :name "Debug the merge queue")
                               :id))
           (origin (harness-ui-quick-search-test--origin)))
      (harness-test-wait (lambda () (eq 'done (plist-get (harness-call 'task/get task) :state)))
                         5 "the task to finish")
      (harness-ui-quick-search-test--ask
       origin "the merge queue"
       (format "{\"show\":[\"%s\"],\"sessions\":[\"%s\"],\"commands\":[\"harness-quick-search-test-run\"],\"note\":\"These match.\"}"
               task session))
      (let ((text (harness-ui-quick-search-test--text)))
        (should (string-match-p "“the merge queue” · 1 command, 1 session, 1 task" text))
        (should (string-match-p "These match\\." text))
        ;; Commands first, as a search from here favours them.
        (should (string-match-p "Commands\n.*C-c z Note the buffer this runs in.*(harness-quick-search-test-run)  \\[Run\\] \\[Describe\\]"
                                text))
        (should (string-match-p "Sessions\n.*Debug the merge queue  chat · .* · updated .*\\[Open\\]" text))
        (should (string-match-p (format "Tasks\n  %s Write the docs  .*\\[Board\\]" (regexp-quote task)) text))
        (should (< (string-search "Commands" text) (string-search "Sessions" text) (string-search "Tasks" text)))
        (should (string-match-p "\\[Search sessions\\] \\[Search commands\\]" text)))
      ;; [Open] opens the session from where the search was opened.
      (let ((visited nil))
        (cl-letf (((symbol-function 'harness-ui-visit-session)
                   (lambda (id &rest _) (push (cons id (current-buffer)) visited) nil)))
          (harness-ui-quick-search-test--push "[Open]"))
        (should (equal session (car (car visited))))
        (should (eq origin (cdr (car visited))))
        (should-not (harness-ui-quick-search-test--popout))))))

(ert-deftest harness-ui-quick-search-run-and-board ()
  "[Run] runs the command in the buffer the search was opened from; [Board] shows the task."
  (harness-ui-quick-search-test-with
    (let* ((task (plist-get (harness-call 'task/submit default-directory "Fix the flaky test") :id))
           (origin (harness-ui-quick-search-test--origin))
           (other (get-buffer-create "*quick search other*")))
      (unwind-protect
          (progn
            (harness-test-wait (lambda () (eq 'done (plist-get (harness-call 'task/get task) :state)))
                               5 "the task to finish")
            (harness-ui-quick-search-test--ask origin "run the test command"
                                               "{\"commands\":[\"harness-quick-search-test-run\"]}")
            ;; Even when the origin's window shows another buffer by then.
            (with-selected-window (get-buffer-window origin) (switch-to-buffer other))
            (harness-ui-quick-search-test--push "[Run]")
            (should (eq origin harness-ui-quick-search-test--ran))
            (should (eq origin (window-buffer (selected-window))))
            (should-not (harness-ui-quick-search-test--popout))
            ;; A command not interned, or not the harness's, never runs.
            (should-error (harness-quick-search-run-command "harness-no-such-command-at-all") :type 'user-error)
            (should-error (harness-quick-search-run-command "delete-other-windows") :type 'user-error)
            ;; [Board] shows the task on its board.
            (harness-ui-quick-search-test--ask origin "the flaky test" (format "{\"show\":[\"%s\"]}" task))
            (let ((shown nil))
              (cl-letf (((symbol-function 'harness-ui-tasks-search-show-plan)
                         (lambda (plan) (push (cons plan (current-buffer)) shown))))
                (harness-ui-quick-search-test--push "[Board]"))
              (should (equal (list :ids (list task) :query "the flaky test") (car (car shown))))
              (should (eq 'harness-ui-tasks-mode (buffer-local-value 'major-mode (cdr (car shown)))))
              (should (equal (file-name-as-directory (expand-file-name dir))
                             (buffer-local-value 'harness-ui-tasks--dir (cdr (car shown)))))))
        (kill-buffer other)))))

(ert-deftest harness-ui-quick-search-board-target ()
  "[Board] shows its task first, then the search's other tasks, each once."
  (harness-ui-quick-search-test-with
    (with-temp-buffer
      (setq-local harness-quick-search--context (list :view "buffer" :project "/tmp/p/"))
      (setq-local harness-quick-search--state
                  (list :query "typed" :plan (list :ids (list "b" "a") :query "the q"
                                                   :tasks (list (list :id "a") (list :id "c")))))
      (cl-letf (((symbol-function 'harness-quick-search--quick-search-popout-p) #'always))
        (should (equal (list (list "a" "b" "c") "the q" "/tmp/p/")
                       (harness-quick-search--task-target "a"))))
      ;; The plan is left as it was.
      (should (equal (list "b" "a") (plist-get (plist-get harness-quick-search--state :plan) :ids))))))

(ert-deftest harness-ui-quick-search-nothing-found ()
  "An answer with nothing, even widened, says so."
  (harness-ui-quick-search-test-with
    (harness-ui-quick-search-test--ask (harness-ui-quick-search-test--origin) "xyzzy plugh"
                                       "{\"show\":[],\"do\":[]}")
    (let ((plan (plist-get (harness-ui-quick-search-test--state) :plan))
          (text (harness-ui-quick-search-test--text)))
      (should (eq t (plist-get plan :widened)))
      (should (string-match-p
               "Nothing found for “xyzzy plugh”: no task, session or command, even searching wider\\." text))
      (should-not (string-match-p "Could not draw" text))
      (should (string-match-p "\\[Search sessions\\]" text)))
    ;; [Search sessions] asks again, favouring sessions.
    (setq harness-ui-quick-search-test--requests nil)
    (harness-ui-quick-search-test--push "[Search sessions]")
    (harness-ui-quick-search-test--wait-status 'done)
    (should (equal "sessions" (plist-get (harness-ui-quick-search-test--state) :bias)))
    (should (string-match-p "Favour sessions" (harness-ui-quick-search-test--first-text)))
    (should (string-match-p "favours sessions, then commands" (harness-ui-quick-search-test--text)))))

(ert-deftest harness-ui-quick-search-drops-older-answers ()
  "An answer to a search asked before the latest is dropped."
  (harness-ui-quick-search-test-with
    (let ((origin (harness-ui-quick-search-test--origin)))
      (harness-ui-quick-search-test--ask origin "the first search" "{\"show\":[],\"do\":[]}")
      (let* ((popout (harness-ui-quick-search-test--popout))
             (seq (buffer-local-value 'harness-quick-search--seq popout))
             (state (harness-ui-quick-search-test--state)))
        ;; An answer for the search before: left alone.
        (should-not (harness-quick-search--arrived popout (1- seq) '(:query "stale" :commands nil)))
        (should (eq state (harness-ui-quick-search-test--state)))
        ;; Two searches at once: only the latest one's answer shows.
        (setq harness-ui-quick-search-test--replies
              '("{\"commands\":[\"harness-quick-search-test-run\"]}" "{\"show\":[],\"do\":[]}")
              harness-ui-quick-search-test--requests nil)
        (with-current-buffer origin (harness-quick-search "the older one"))
        (with-current-buffer origin (harness-quick-search "the newer one"))
        (harness-test-wait (lambda () (>= (length harness-ui-quick-search-test--requests) 2)) 5 "both searches")
        (harness-ui-quick-search-test--wait-status 'done)
        ;; Time for the older answer to arrive too, were it not dropped.
        (harness-ui-quick-search-test--pause 0.3)
        (let ((state (harness-ui-quick-search-test--state)))
          (should (eq 'done (plist-get state :status)))
          (should (equal "the newer one" (plist-get state :query)))
          (should (equal "the newer one" (plist-get (plist-get state :plan) :query)))
          (should (= (buffer-local-value 'harness-quick-search--seq popout) (plist-get state :seq))))))))

(provide 'harness-ui-quick-search-test)
;;; harness-ui-quick-search-test.el ends here
