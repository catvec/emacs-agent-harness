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
(defvar harness-quick-search--scan-cache)
(defvar harness-quick-search--scan-stale)
(defvar harness-quick-search--scan-timer)
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
(declare-function harness-quick-search--scan "harness-ui-quick-search")
(declare-function harness-quick-search--idle-build "harness-ui-quick-search")
(declare-function harness-quick-search--after-load "harness-ui-quick-search")
(declare-function harness-quick-search--reset-scan "harness-ui-quick-search")
(declare-function harness-quick-search--init "harness-ui-quick-search")
(declare-function harness-quick-search--shutdown "harness-ui-quick-search")
(declare-function harness-quick-search--text "harness-ui-quick-search")
(declare-function harness-quick-search-open-session "harness-ui-quick-search")
(declare-function harness-search-sessions "harness-ui-search")
(declare-function harness-ui-chat-goto-node "harness-ui-chat")
(declare-function harness-ui-visit-session "harness-ui")
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
                          session-search tasks-search acp))
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
       (dolist (m '(ui ui-compose ui-popout ui-chat ui-tasks ui-search ui-quick-search))
         (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (unwind-protect
           (save-window-excursion
             (delete-other-windows)
             ,@body)
         ;; No scan of the commands, and no idle job to build one, is left
         ;; for the next test.
         (harness-quick-search--reset-scan)
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

(defun harness-ui-quick-search-test--push (label &optional nth)
  "Push the button LABEL of the popout: the first, or with NTH the one after NTH."
  (with-current-buffer (harness-ui-quick-search-test--popout)
    (goto-char (point-min))
    (dotimes (_ (or nth 0))
      (should (search-forward label nil t)))
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

(defmacro harness-ui-quick-search-test--counting-scans (var &rest body)
  "Run BODY with VAR the number of walks over the symbols made so far."
  (declare (indent 1))
  `(let ((,var 0)
         (walk (symbol-function 'harness-quick-search--scan)))
     (cl-letf (((symbol-function 'harness-quick-search--scan)
                (lambda () (cl-incf ,var) (funcall walk))))
       ,@body)))

(defun harness-ui-quick-search-test--timers ()
  "How many idle timers wait to build the scan of the commands."
  (cl-count #'harness-quick-search--idle-build timer-idle-list :key #'timer--function))

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

;;;; The scan of the commands, built ahead

(ert-deftest harness-ui-quick-search-scans-once-when-nothing-is-built ()
  "With no scan built, a catalogue builds it on the spot, once; none walks
the symbols again, for this buffer or another."
  (harness-ui-quick-search-test-with
    (harness-quick-search--reset-scan)
    (harness-ui-quick-search-test--counting-scans scans
      (should (with-temp-buffer (text-mode) (harness-quick-search-commands)))
      (should (= 1 scans))
      (should harness-quick-search--scan-cache)
      (should-not harness-quick-search--scan-stale)
      (with-temp-buffer (harness-chat-mode) (harness-quick-search-commands))
      (with-temp-buffer (text-mode) (harness-quick-search-commands))
      (should (= 1 scans)))))

(ert-deftest harness-ui-quick-search-idle-job-builds-the-scan-ahead ()
  "Once the idle job has run, a catalogue walks no symbols, in any buffer,
and is what the catalogue built on the spot was."
  (harness-ui-quick-search-test-with
    (harness-quick-search--reset-scan)
    (let ((on-the-spot (with-temp-buffer (harness-chat-mode) (harness-quick-search-commands))))
      (harness-quick-search--reset-scan)
      (harness-ui-quick-search-test--counting-scans scans
        (harness-quick-search--idle-build)
        (should (= 1 scans))
        (should harness-quick-search--scan-cache)
        (should-not harness-quick-search--scan-timer)
        (should-not harness-quick-search--scan-stale)
        (let ((chat (with-temp-buffer (harness-chat-mode) (harness-quick-search-commands)))
              (plain (with-temp-buffer (text-mode) (harness-quick-search-commands))))
          (should (equal on-the-spot chat))
          (should (harness-ui-quick-search-test--entry "harness-compose-add-attachment" plain))
          ;; What the buffer decides is still the buffer's.
          (should (eq t (plist-get (harness-ui-quick-search-test--entry "harness-compose-add-attachment" chat) :here)))
          (should (eq :false (plist-get (harness-ui-quick-search-test--entry "harness-compose-add-attachment" plain) :here))))
        (should (= 1 scans))))))

(ert-deftest harness-ui-quick-search-a-load-marks-the-scan-stale ()
  "A file that loads marks the scan stale and has one rebuild scheduled, however
many load.  The stale scan serves, with no walk, and lacks what the file
defined; the idle job builds it again, and it is there."
  (harness-ui-quick-search-test-with
    (harness-quick-search--reset-scan)
    (harness-quick-search--idle-build)
    (should-not harness-quick-search--scan-stale)
    (should (= 0 (harness-ui-quick-search-test--timers)))
    (let ((file (make-temp-file "harness-quick-search-test-" nil ".el"
                                (concat ";;; -*- lexical-binding: t -*-\n"
                                        "(defun harness-quick-search-test-loaded ()\n"
                                        "  \"A command that loads late.\"\n  (interactive))\n"))))
      (unwind-protect
          (harness-ui-quick-search-test--counting-scans scans
            (load file nil t)
            (load file nil t)
            (should harness-quick-search--scan-stale)
            (should (= 1 (harness-ui-quick-search-test--timers)))
            ;; Served as it is: no walk, and nothing the file defined yet.
            (let ((stale (with-temp-buffer (text-mode) (harness-quick-search-commands))))
              (should (= 0 scans))
              (should-not (harness-ui-quick-search-test--entry "harness-quick-search-test-loaded" stale)))
            ;; The idle job builds it again, once.
            (harness-quick-search--idle-build)
            (should (= 1 scans))
            (should-not harness-quick-search--scan-stale)
            (should (= 0 (harness-ui-quick-search-test--timers)))
            (should (harness-ui-quick-search-test--entry
                     "harness-quick-search-test-loaded"
                     (with-temp-buffer (text-mode) (harness-quick-search-commands))))
            ;; A scan that is not stale is left as it is.
            (harness-quick-search--idle-build)
            (should (= 1 scans)))
        (delete-file file)
        (fmakunbound 'harness-quick-search-test-loaded)))))

(ert-deftest harness-ui-quick-search-typing-stops-the-idle-build ()
  "A key waiting, or typed during the walk, stops the idle build; the scan
that served stays, stale, and the next idle moment tries again."
  (harness-ui-quick-search-test-with
    (harness-quick-search--reset-scan)
    ;; Nothing built yet, and a key waiting: no walk is begun.
    (let ((unread-command-events (list ?a)))
      (harness-ui-quick-search-test--counting-scans scans
        (harness-quick-search--idle-build)
        (should (= 0 scans))))
    (should-not harness-quick-search--scan-cache)
    (should (= 1 (harness-ui-quick-search-test--timers)))
    ;; A scan built, a file loaded since.
    (harness-quick-search--reset-scan)
    (harness-quick-search--idle-build)
    (harness-quick-search--after-load "x.el")
    (let ((old harness-quick-search--scan-cache))
      ;; A key typed during the walk: the walk stops, nothing half built is kept.
      (let ((walks 0))
        (cl-letf (((symbol-function 'harness-quick-search--scan)
                   (lambda ()
                     (cl-incf walks)
                     (setq quit-flag throw-on-input)
                     (dotimes (_ 10) (harness-quick-search--text "typing"))
                     (error "The walk was not stopped"))))
          (harness-quick-search--idle-build))
        (should (= 1 walks)))
      (should (eq old harness-quick-search--scan-cache))
      (should harness-quick-search--scan-stale)
      (should (= 1 (harness-ui-quick-search-test--timers)))
      ;; At the next idle moment, nothing in the way, it builds.
      (harness-quick-search--idle-build)
      (should-not (eq old harness-quick-search--scan-cache))
      (should-not harness-quick-search--scan-stale)
      (should (= 0 (harness-ui-quick-search-test--timers))))))

(ert-deftest harness-ui-quick-search-module-builds-the-scan-ahead ()
  "The module's init forgets an earlier scan, hooks the loads and has the scan
built when Emacs is idle, one timer however often it runs; its shutdown
unhooks, cancels the timer and forgets the scan."
  (harness-ui-quick-search-test-with
    (unwind-protect
        (progn
          (setq harness-quick-search--scan-cache (list :modes nil :commands nil :docs (make-hash-table))
                harness-quick-search--scan-stale t)
          (harness-quick-search--init)
          (should (memq #'harness-quick-search--after-load after-load-functions))
          (should-not harness-quick-search--scan-cache)
          (should-not harness-quick-search--scan-stale)
          (should (= 1 (harness-ui-quick-search-test--timers)))
          (harness-quick-search--init)
          (should (= 1 (harness-ui-quick-search-test--timers)))
          ;; Built, then a load: one timer waits.
          (harness-quick-search--idle-build)
          (should harness-quick-search--scan-cache)
          (run-hook-with-args 'after-load-functions "x.el")
          (should (= 1 (harness-ui-quick-search-test--timers)))
          ;; Shut down.
          (harness-quick-search--shutdown)
          (should-not (memq #'harness-quick-search--after-load after-load-functions))
          (should-not harness-quick-search--scan-cache)
          (should (= 0 (harness-ui-quick-search-test--timers)))
          (run-hook-with-args 'after-load-functions "y.el")
          (should (= 0 (harness-ui-quick-search-test--timers))))
      (harness-quick-search--init))))

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
        (should (string-match-p "Sessions  \\[All matches\\]\n.*Debug the merge queue  chat · .* · updated .*\\[Open\\]" text))
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

(ert-deftest harness-ui-quick-search-open-goes-to-the-match ()
  "[Open] on a session the search found in a transcript opens it at that
message, the words found there to be highlighted; on one found by its name
only it just opens.  An id with the node, the snippet and the ranges opens
at the match too."
  (harness-ui-quick-search-test-with
    (let* ((merge (plist-get (harness-call 'session/create :cwd default-directory :name "Fix a thing") :id))
           (notes (plist-get (harness-call 'session/create :cwd default-directory
                                           :name "Write the release notes")
                             :id))
           (node (plist-get (harness-call 'session/append merge
                                          (list :kind 'user :content "Why did the merge queue drop a commit?"))
                            :id))
           (origin (harness-ui-quick-search-test--origin))
           (visited nil)
           (went nil))
      (cl-letf (((symbol-function 'harness-ui-visit-session)
                 (lambda (id &rest _) (push (cons id (current-buffer)) visited) nil))
                ((symbol-function 'harness-ui-chat-goto-node)
                 (lambda (&rest args) (push args went) nil)))
        ;; The model searched the transcripts, and named both sessions.
        (harness-ui-quick-search-test--ask
         origin "the queue that dropped a commit"
         "{\"sessions\":\"merge queue\"}"
         (format "{\"sessions\":[\"%s\",\"%s\"]}" (substring merge 0 8) (substring notes 0 8)))
        (let ((entries (plist-get (plist-get (harness-ui-quick-search-test--state) :plan) :sessions)))
          (should (equal (list merge notes) (mapcar (lambda (s) (plist-get s :id)) entries)))
          (should (equal node (plist-get (car entries) :node)))
          (should-not (plist-get (cadr entries) :node)))
        ;; The first [Open]: the session, from where the search was opened,
        ;; then its node, on the words found.
        (harness-ui-quick-search-test--push "[Open]")
        (should (equal (cons merge origin) (car visited)))
        (should-not (harness-ui-quick-search-test--popout))
        (should (= 1 (length went)))
        (pcase-let ((`(,goto-node ,goto-session ,regexp) (car went)))
          (should (equal node goto-node))
          (should (equal merge goto-session))
          (should (string-match-p regexp "Merge"))
          (should (string-match-p regexp "queue"))
          (should-not (string-match-p regexp "commit")))
        ;; One found by its name only opens as it is.
        (harness-ui-quick-search-test--ask origin "the release notes"
                                           (format "{\"sessions\":[\"%s\"]}" (substring notes 0 8)))
        (harness-ui-quick-search-test--push "[Open]")
        (should (equal notes (car (car visited))))
        (should (= 1 (length went)))
        ;; An id with the parts of its match opens at it, an id alone does not.
        (let* ((snippet "Why did the merge queue drop a commit?")
               (from (string-search "merge queue" snippet)))
          (harness-quick-search-open-session
           merge node snippet (list (list from (+ from 5)) (list (+ from 6) (+ from 11)))))
        (should (equal merge (car (car visited))))
        (should (= 2 (length went)))
        (should (equal (list node merge "merge\\|queue") (car went)))
        (harness-quick-search-open-session notes)
        (should (equal notes (car (car visited))))
        (should (= 2 (length went)))))))

(ert-deftest harness-ui-quick-search-all-matches-shows-every-match ()
  "The Sessions heading has [All matches] when sessions were found: it
closes the popout and has the session search show every match of the line,
from where the quick search was opened.  With no session found there is none."
  (harness-ui-quick-search-test-with
    (let* ((session (plist-get (harness-call 'session/create :cwd default-directory
                                             :name "Debug the merge queue")
                               :id))
           (origin (harness-ui-quick-search-test--origin))
           (searched nil))
      (harness-ui-quick-search-test--ask origin "the merge queue" (format "{\"sessions\":[\"%s\"]}" session))
      (should (string-match-p "Sessions  \\[All matches\\]\n" (harness-ui-quick-search-test--text)))
      (cl-letf (((symbol-function 'harness-search-sessions)
                 (lambda (query &optional mode) (push (list query mode (current-buffer)) searched) nil)))
        (harness-ui-quick-search-test--push "[All matches]"))
      (should (equal (list (list "the merge queue" nil origin)) searched))
      (should-not (harness-ui-quick-search-test--popout))
      ;; Nothing found among the sessions: no button.
      (harness-ui-quick-search-test--ask origin "run the test command"
                                         "{\"commands\":[\"harness-quick-search-test-run\"]}")
      (should-not (string-match-p "All matches" (harness-ui-quick-search-test--text))))))

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
