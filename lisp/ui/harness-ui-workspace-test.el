;;; harness-ui-workspace-test.el --- Tests for the workspace UI  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-acp--server-enabled)
(defvar harness-acp-token)
(defvar harness-ui-map)
(defvar harness-ui-event-functions)
(defvar harness-ui--queue)
(defvar harness-ui-workspace--data)
(defvar harness-ui-workspace--entries)
(defvar harness-ui-workspace--id)
(defvar harness-ui-workspace--knowledge)
(defvar harness-ui-workspace--state)
(defvar harness-ui-workspace--thread)
(defvar harness-ui--sessions)

(defmacro harness-ui-workspace-test-with (&rest body)
  "Load the UI and the workspace front end, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil)
           (harness-acp-token nil))
       (harness-test-load-module 'acp)
       (harness-test-load-module 'ui)
       (harness-test-load-module 'ui-chat)
       (harness-test-load-module 'ui-compose)
       (harness-test-load-module 'ui-workspace)
       (harness-ui-pending--forget-all)
       (unwind-protect (progn ,@body)
         (harness-ui-pending--forget-all)
         (harness-ui-workspace--shutdown)))))

(defun harness-ui-workspace-test-data ()
  "Return a fresh workspace plist for the tests.
A case may change a thread's status or add one, and the next case
must see the fixture as it was."
  (copy-tree
   '(:id "w-1"
    :name "Home"
    :root "/tmp/workspace/"
    :last-thread "th-1"
    :threads ((:id "th-1" :title "Kitchen renovation" :state "live"
                    :episode-status "running" :pending nil
                    :live "s-1" :episodes ("s-1") :pinned t :last-at 20.0
                    :model "demo:scripted" :thinking "medium"
                    :permission-mode "auto" :non-interactive nil)
              (:id "th-2" :title "Harness memory" :state "parked"
                    :episode-status "parked" :pending nil
                    :live nil :episodes ("s-0") :pinned nil :last-at 10.0
                    :model "demo:scripted" :thinking "medium"
                    :permission-mode "auto" :non-interactive nil)))))

(defun harness-ui-workspace-test-entries ()
  "Return timeline entries for the tests."
  '((:kind "divider" :thread "th-1" :title "Kitchen renovation" :reason "new-thread")
    (:kind "brief" :thread "th-1" :tokens 120)
    (:kind "message" :thread "th-1" :role "user" :text "The tile is matte.")
    (:kind "message" :thread "th-1" :role "assistant" :text "Noted.")))

(defun harness-ui-workspace-test-render (&optional computers)
  "Render a test workspace in the current buffer and return its text.
COMPUTERS, when given, is what the registered computers are."
  (harness-ui-workspace-mode)
  (setq harness-ui-workspace--id "w-1"
        harness-ui-workspace--thread "th-1"
        harness-ui-workspace--state 'ready
        harness-ui-workspace--data (harness-ui-workspace-test-data)
        harness-ui-workspace--entries (harness-ui-workspace-test-entries)
        harness-ui-workspace--knowledge nil
        harness-ui-workspace--computers computers)
  (cl-letf (((symbol-function 'harness-compose-fetch-completions) #'ignore))
    (harness-ui-workspace--render))
  (buffer-string))

(ert-deftest harness-ui-workspace-shows-the-one-chat ()
  "The header, thread list, divider and messages render as one chat."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (let ((text (harness-ui-workspace-test-render)))
        (should (string-match-p "Workspace · Home" text))
        (should (string-match-p "Thread · Kitchen renovation" text))
        (should (string-match-p "Tasks" text))
        (should (string-match-p "New thread" text))
        (should (string-match-p "Refresh" text))
        (should (string-match-p "Threads" text))
        (should (string-match-p "Kitchen renovation" text))
        (should (string-match-p "Harness memory" text))
        (should (string-match-p "New thread · Kitchen renovation" text))
        (should (string-match-p "Brief · 120 tokens" text))
        (should (string-match-p "You" text))
        (should (string-match-p "The tile is matte." text))
        (should (string-match-p "Agent" text))
        (should (string-match-p "Noted." text))
        (should (equal "Message…" (funcall harness-compose-placeholder-function)))))))

(ert-deftest harness-ui-workspace-names-a-switched-to-thread ()
  "A message routed to another thread is named with that thread."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-mode)
      (setq harness-ui-workspace--id "w-1"
            harness-ui-workspace--thread "th-1"
            harness-ui-workspace--state 'ready
            harness-ui-workspace--data (harness-ui-workspace-test-data)
            harness-ui-workspace--entries
            (append (harness-ui-workspace-test-entries)
                    '((:kind "message" :thread "th-2" :role "user"
                             :text "And the subscription?")
                      (:kind "message" :thread "th-2" :role "assistant"
                             :text "Cancelled.")))
            harness-ui-workspace--knowledge nil)
      (cl-letf (((symbol-function 'harness-compose-fetch-completions) #'ignore))
        (harness-ui-workspace--render))
      (let ((text (buffer-string)))
        (should (string-match-p "Thread · Harness memory" text))
        ;; Named once, before the message that switched to it; its
        ;; reply, and the messages before it, carry no second name.
        (should (= 1 (cl-count-if (lambda (line)
                                    (string-match-p "\\`Thread · Harness memory\\'" line))
                                  (split-string text "\n"))))
        (should (string-match-p "The tile is matte." text))
        (should (string-match-p "Cancelled." text))))))

(ert-deftest harness-ui-workspace-computers-are-one-click-away ()
  "The workspace shows the registered computers, their screen share and control."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (let* ((computers '((:id "local" :name "marcuse" :connected t
                           :vnc "http://127.0.0.1:6080/vnc_lite.html" :control nil)
                          (:id "cmp-box" :name "box" :state "registered"
                           :vnc nil :control "user")))
             (text (harness-ui-workspace-test-render computers)))
        (should (string-match-p "Computers" text))
        (should (string-match-p "marcuse" text))
        (should (string-match-p "Live" text))
        (should (string-match-p "box" text))
        (should (string-match-p "Registered" text))
        (should (string-match-p "View" text))
        (should (string-match-p "Control" text))
        (should (string-match-p "Return" text))
        (goto-char (point-min))
        (search-forward "All computers")
        (should (equal "The computers page" (get-text-property (1- (point)) 'help-echo)))
        (search-forward "View")
        (should (equal "screen share of marcuse" (get-text-property (1- (point)) 'help-echo)))
        (search-forward "Control")
        (should (equal "control of marcuse" (get-text-property (1- (point)) 'help-echo)))
        (search-forward "Return")
        (should (equal "control return of box" (get-text-property (1- (point)) 'help-echo)))))))

(ert-deftest harness-ui-workspace-loading-draws-before-the-first-answer ()
  "The loading state draws without a workspace root to list files from."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-mode)
      (setq harness-ui-workspace--id "w-1"
            harness-ui-workspace--state 'loading
            harness-ui-workspace--data nil)
      (harness-ui-workspace--render)
      (let ((text (buffer-string)))
        (should (string-match-p "Workspace · loading" text))
        (should (string-match-p "Loading…" text))))))

(ert-deftest harness-ui-workspace-header-copy-and-tooltips ()
  "The header's exact words and the buttons' tooltips are the inventory's."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-mode)
      (setq harness-ui-workspace--id "w-1"
            harness-ui-workspace--thread "th-1"
            harness-ui-workspace--state 'ready
            harness-ui-workspace--data (harness-ui-workspace-test-data)
            harness-ui-workspace--entries nil
            harness-ui-workspace--knowledge '(:available t :notes 2))
      (cl-letf (((symbol-function 'harness-compose-fetch-completions) #'ignore))
        (harness-ui-workspace--render))
      (goto-char (point-min))
      (should (equal (buffer-substring-no-properties (line-beginning-position) (line-end-position))
                     "Workspace · Home   Thread · Kitchen renovation · Running   Knowledge · ready   Computer · off   Tasks New thread Episode Stop Refresh Graph Workspace computer Resources"))
      (search-forward "Tasks")
      (should (equal "The task board of this workspace" (get-text-property (1- (point)) 'help-echo)))
      (search-forward "New thread")
      (should (equal "Start a new topic" (get-text-property (1- (point)) 'help-echo)))
      (search-forward "Refresh")
      (should (equal "Read the workspace again" (get-text-property (1- (point)) 'help-echo)))
      (search-forward "Graph")
      (should (equal "The Logseq nodes of this thread"
                     (get-text-property (1- (point)) 'help-echo)))
      (search-forward "Workspace computer")
      (should (equal "workspace computer page"
                     (get-text-property (1- (point)) 'help-echo))))))

(ert-deftest harness-ui-workspace-empty-and-error-states ()
  "The empty and failed workspace states say so in noun phrases."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-mode)
      (setq harness-ui-workspace--id "w-1"
            harness-ui-workspace--state 'ready
            harness-ui-workspace--data (list :id "w-1" :name "Home" :threads nil)
            harness-ui-workspace--entries nil)
      (cl-letf (((symbol-function 'harness-compose-fetch-completions) #'ignore))
        (harness-ui-workspace--render))
      (should (string-match-p "No threads" (buffer-string)))
      (should (string-match-p "No messages" (buffer-string)))
      (should (string-match-p "Knowledge · unavailable" (buffer-string)))
      (setq harness-ui-workspace--knowledge '(:available nil)
            harness-ui-workspace--state 'ready)
      (cl-letf (((symbol-function 'harness-compose-fetch-completions) #'ignore))
        (harness-ui-workspace--render))
      (should (string-match-p "Knowledge · unavailable" (buffer-string)))
      (setq harness-ui-workspace--state 'error
            harness-ui-workspace--error "The harness is out of reach.")
      (cl-letf (((symbol-function 'harness-compose-fetch-completions) #'ignore))
        (harness-ui-workspace--render))
      (should (string-match-p "Workspace · unavailable" (buffer-string)))
      (should (string-match-p "Retry" (buffer-string))))))

(ert-deftest harness-ui-workspace-sends-the-box-text ()
  "Sending the compose box calls workspace/prompt with the thread."
  (harness-ui-workspace-test-with
    (let (sent)
      (with-temp-buffer
        (harness-ui-workspace-test-render)
        (let ((inhibit-read-only t))
          (harness-compose-insert "Please remember the matte tile."))
        (cl-letf (((symbol-function 'harness-ui-call)
                   (lambda (method params callback &optional _on-error)
                     (push (list method params) sent)
                     (funcall callback nil)))
                  ((symbol-function 'harness-compose-fetch-completions) #'ignore))
          (harness-ui-workspace-send))
        (should (equal "_harness/workspace/prompt" (caar sent)))
        (should (equal "w-1" (plist-get (cadar sent) :id)))
        (should (equal "th-1" (plist-get (plist-get (cadar sent) :opts) :thread)))
        (should (string-match-p "matte tile" (plist-get (cadar sent) :text)))))))

(ert-deftest harness-ui-workspace-renders-the-loading-state ()
  "The loading state draws before the harness answers, with a project.
The compose box completes from the buffer's directory until the
workspace plist arrives, so the first render must not pass it nil."
  (harness-ui-workspace-test-with
    (let ((dir (file-name-as-directory (make-temp-file "harness-workspace-" t))))
      (unwind-protect
          (with-temp-buffer
            (setq default-directory dir)
            (harness-ui-workspace-mode)
            (setq harness-ui-workspace--id "w-1"
                  harness-ui-workspace--state 'loading
                  harness-ui-workspace--data nil
                  harness-ui-workspace--entries nil)
            (let ((harness-ui--queue nil))
              (harness-ui-workspace--render))
            (should (equal dir (harness-compose--project)))
            (should (string-match-p "Workspace · loading" (buffer-string)))
            (should (string-match-p "Loading…" (buffer-string))))
        (delete-directory dir t)))))

(ert-deftest harness-ui-workspace-open-shows-the-buffer ()
  "Opening a workspace shows its buffer before the data arrives.
That is what C-c h Y does: the loading chat appears at once, from the
workspace root, instead of no buffer at all."
  (harness-ui-workspace-test-with
    (let (shown)
      (unwind-protect
          (with-temp-buffer
            (let ((harness-ui--queue nil))
              (cl-letf (((symbol-function 'harness-ui-display-view)
                         (lambda (buffer &optional _position) (setq shown buffer)))
                        ((symbol-function 'harness-compose-fetch-completions) #'ignore))
                (harness-ui-workspace--open (harness-ui-workspace-test-data))))
            (should (buffer-live-p shown))
            (with-current-buffer shown
              (should (derived-mode-p 'harness-ui-workspace-mode))
              (should (equal "/tmp/workspace/" default-directory))
              (should (equal "/tmp/workspace/" (harness-compose--project)))
              (should (string-match-p "Workspace · loading" (buffer-string)))
              (should (string-match-p "Loading…" (buffer-string)))))
        (when (buffer-live-p (get-buffer "*harness workspace: Home*"))
          (kill-buffer "*harness workspace: Home*"))))))

(ert-deftest harness-ui-workspace-fetch-shows-the-knowledge-state ()
  "The fetch asks for the workspace's knowledge and the header names it ready.
The request names the parameter the method takes, `workspace', as the
client's does."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-mode)
      (setq harness-ui-workspace--id "w-1"
            harness-ui-workspace--state 'loading
            harness-ui-workspace--data nil
            harness-ui-workspace--entries nil)
      (let (requests)
        (let ((harness-ui--queue nil))
          (cl-letf (((symbol-function 'harness-ui-request)
                     (lambda (method &optional params)
                       (push (cons method params) requests)
                       (harness-resolved
                        (pcase method
                          ("_harness/workspace/get" (harness-ui-workspace-test-data))
                          ("_harness/workspace/timeline" (harness-ui-workspace-test-entries))
                          ("_harness/knowledge/status" (list :available t :notes 2))
                          (_ nil)))))
                    ((symbol-function 'harness-compose-fetch-completions) #'ignore))
            (harness-ui-workspace--fetch)))
        (should (equal (list :workspace "w-1") (cdr (assoc "_harness/knowledge/status" requests))))
        (harness-test-wait (lambda () (string-match-p "Knowledge · ready" (buffer-string))))
        (should (string-match-p "The tile is matte." (buffer-string)))))))

(ert-deftest harness-ui-workspace-refuses-an-empty-message ()
  "An empty send is a user error, not a turn."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-test-render)
      (let ((inhibit-read-only t))
        (harness-compose-insert ""))
      (should-error (harness-ui-workspace-send) :type 'user-error))))

(ert-deftest harness-ui-workspace-resources-render-shows-metadata-only ()
  "The resources page shows labels and counts, never a value."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-resources-mode)
      (setq harness-ui-workspace-resources--id "w-1"
            harness-ui-workspace-resources--data
            (list :status "ready"
                  :metadata-only t
                  :browser (list :profile (list :label "browser" :kind "Firefox" :sites 2)
                                 :sites (list (list :origin "https://stoneco.example"
                                                    :cookies 12 :auth "signed-in"
                                                    :value "SESSION-VALUE"))
                                 :logins (list (list :origin "https://stoneco.example"
                                                     :username "" :state "active")))
                  :wallet nil
                  :credentials (list (list :label "deploy-key"
                                           :fingerprint "4f9c2a1b" :usable t))
                  :credentials-status (list :status "ready")
                  :access nil :audit nil))
      (harness-ui-workspace-resources--render)
      (let ((text (buffer-string)))
        (should (string-match-p "Workspace resources" text))
        (should (string-match-p "Metadata only" text))
        (should (string-match-p "Profile · browser" text))
        (should (string-match-p "Firefox · 2 sites" text))
        (should (string-match-p "stoneco.example" text))
        (should (string-match-p "12 cookies" text))
        (should (string-match-p "site session · active" text))
        (should (string-match-p "deploy-key" text))
        (should (string-match-p "Locked run · ready" text))
        (should (string-match-p "Payment broker" text))
        (should-not (string-match-p "SESSION-VALUE" text))))))

(ert-deftest harness-ui-workspace-resources-render-says-what-is-missing ()
  "An unavailable answer names the missing module, not a blank page."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-resources-mode)
      (setq harness-ui-workspace-resources--id "w-1"
            harness-ui-workspace-resources--data
            (list :status "unavailable"
                  :credentials nil
                  :credentials-status (list :status "unavailable" :why "Masking off")
                  :browser nil
                  :browser-reason (list :code "box-tools-missing"
                                        :text "workspace computer tools missing: Xvfb")
                  :wallet nil :access nil :audit nil))
      (harness-ui-workspace-resources--render)
      (let ((text (buffer-string)))
        (should (string-match-p "Unavailable" text))
        (should (string-match-p "box-tools-missing" text))
        (should (string-match-p "No browser data" text))
        (should (string-match-p "Masking off" text))
        (should (string-match-p "No credentials" text))
        (should (string-match-p "g · refresh" text))
        (should (string-match-p "q · bury" text))))))

(ert-deftest harness-ui-workspace-resources-has-a-key ()
  "The workspace buffer opens the resources page with C-c w R."
  (harness-ui-workspace-test-with
    (should (eq (lookup-key harness-ui-workspace-mode-map (kbd "C-c w R"))
                #'harness-ui-workspace-resources))))

(defun harness-ui-workspace-test-permission (&optional id session title)
  "Add a pending permission request to SESSION, with ID and TITLE."
  (harness-ui-pending-add
   (or session "s-1")
   (list :id (or id "p-1") :kind "permission" :created (- (float-time) 1)
         :title (or title "Run the command") :tool "bash"
         :tool-kind "execute" :options '("allow-once" "deny-once"))))

(defun harness-ui-workspace-test-question (&optional id session question options multiple)
  "Add a pending question to SESSION, with ID, QUESTION and OPTIONS.
With MULTIPLE, several options may be ticked."
  (harness-ui-pending-add
   (or session "s-1")
   (list :id (or id "q-1") :kind "question" :created (float-time)
         :question (or question "Which database?")
         :options (or options '("sqlite" "postgres"))
         :allow-multiple (and multiple t))))

(ert-deftest harness-ui-workspace-shows-episode-status ()
  "A thread says Running, Blocked, Idle, Failed, Stopped and Parked."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-test-render)
      (should (string-match-p "Thread · Kitchen renovation · Running" (buffer-string)))
      (should (string-match-p "Kitchen renovation  Running" (buffer-string)))
      (should (string-match-p "Harness memory  Parked" (buffer-string)))
      (let ((thread (car (plist-get harness-ui-workspace--data :threads))))
        (dolist (case '(("blocked" "Blocked · Permission")
                        ("idle" "Idle")
                        ("failed" "Failed")
                        ("stopped" "Stopped")
                        ("inactive" "Inactive")
                        ("parked" "Parked")))
          (setf (plist-get thread :episode-status) (car case))
          (harness-ui-workspace--render)
          (should (string-match-p
                   (concat "Thread · Kitchen renovation · " (regexp-quote (cadr case)))
                   (buffer-string)))
          (should (string-match-p (regexp-quote (cadr case)) (buffer-string))))))))

(ert-deftest harness-ui-workspace-blocked-names-what-it-waits-on ()
  "A blocked episode says whether it waits on a permission or a question."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-test-render)
      (let ((thread (car (plist-get harness-ui-workspace--data :threads))))
        (setf (plist-get thread :episode-status) "blocked")
        (harness-ui-workspace-test-permission)
        (harness-ui-workspace--render)
        (should (string-match-p "Thread · Kitchen renovation · Blocked · Permission"
                                (buffer-string)))
        (harness-ui-pending--forget-all)
        (harness-ui-workspace-test-question)
        (harness-ui-workspace--render)
        (should (string-match-p "Thread · Kitchen renovation · Blocked · Question"
                                (buffer-string)))))))

(ert-deftest harness-ui-workspace-shows-a-pending-permission-card ()
  "The workspace draws the shared pending permission panel.
It says Permission, the call, and the answers every view offers."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-test-render)
      (harness-ui-workspace-test-permission)
      (harness-ui-workspace--render)
      (let ((text (buffer-string)))
        (should (string-match-p "Pending requests" text))
        (should (string-match-p "Permission  Run the command" text))
        (should (string-match-p "Allow" text))
        (should (string-match-p "Deny" text))
        ;; The panel is the selected episode's, and answers in it.
        (should (equal "s-1" harness-ui-pending-session-id))
        (goto-char (point-min))
        (search-forward "Permission")
        (should (equal "p-1" (get-text-property (match-beginning 0)
                                                'harness-ui-pending)))))))

(ert-deftest harness-ui-workspace-shows-a-pending-question-card ()
  "The workspace draws the shared pending question panel with its options."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-test-render)
      (harness-ui-workspace-test-question)
      (harness-ui-workspace--render)
      (let ((text (buffer-string)))
        (should (string-match-p "Pending requests" text))
        (should (string-match-p "Question" text))
        (should (string-match-p "Which database?" text))
        (should (string-match-p "sqlite" text))
        (should (string-match-p "postgres" text))
        (should (equal "s-1" harness-ui-pending-session-id))))))

(ert-deftest harness-ui-workspace-cards-follow-the-thread ()
  "Only the selected thread's live episode's request is drawn and owned."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-test-render)
      ;; A second live thread with its own episode and request.
      (setf (plist-get harness-ui-workspace--data :threads)
            (append (plist-get harness-ui-workspace--data :threads)
                    (list (list :id "th-3" :title "Second topic" :state "live"
                                :episode-status "idle" :pending nil
                                :live "s-2" :episodes (list "s-2") :pinned nil
                                :last-at 5.0))))
      (harness-ui-workspace-test-permission "p-1" "s-1" "First call")
      (harness-ui-workspace-test-permission "p-2" "s-2" "Second call")
      (harness-ui-workspace--render)
      (should (string-match-p "First call" (buffer-string)))
      (should-not (string-match-p "Second call" (buffer-string)))
      (should (equal "s-1" harness-ui-pending-session-id))
      (should (harness-ui-workspace--drawn-p "s-1"))
      (should-not (harness-ui-workspace--drawn-p "s-2"))
      (harness-ui-workspace--select-thread "th-3")
      (should (string-match-p "Second call" (buffer-string)))
      (should-not (string-match-p "First call" (buffer-string)))
      (should (equal "s-2" harness-ui-pending-session-id))
      (should-not (harness-ui-workspace--drawn-p "s-1"))
      (should (harness-ui-workspace--drawn-p "s-2")))))

(ert-deftest harness-ui-workspace-drops-a-resolved-card ()
  "A card goes when the request is answered, here or in another client."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-test-render)
      (harness-ui-workspace-test-permission)
      (harness-ui-workspace--render)
      (should (string-match-p "Permission  Run the command" (buffer-string)))
      ;; Another client answered it: the session says nothing waits.
      (harness-ui-workspace--on-event 'session/pending-changed (list "s-1" nil))
      (should-not (string-match-p "Permission  Run the command" (buffer-string)))
      (should-not (string-match-p "Pending requests" (buffer-string))))))

(ert-deftest harness-ui-workspace-reconciles-a-fetched-pending-list ()
  "A fetched workspace brings in, and takes out, what its episodes wait on."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-test-render)
      (let* ((data (harness-ui-workspace-test-data))
             (thread (car (plist-get data :threads))))
        (setf (plist-get thread :episode-status) "blocked"
              (plist-get thread :pending)
              (list (list :id "p-fetched" :kind "question"
                          :payload (list :question "Proceed?" :options (list "yes" "no")))))
        (harness-ui-workspace--set-data data (harness-ui-workspace-test-entries) nil)
        (should (harness-ui-pending-record "s-1" "p-fetched"))
        (should (string-match-p "Proceed?" (buffer-string)))
        ;; A later view with nothing pending takes the card away.  The
        ;; store keeps a request whose list lags by half a second; this
        ;; one was read before that.
        (setf (plist-get (harness-ui-pending-record "s-1" "p-fetched") :created)
              (- (float-time) 1))
        (setf (plist-get thread :pending) nil
              (plist-get thread :episode-status) "idle")
        (harness-ui-workspace--set-data data (harness-ui-workspace-test-entries) nil)
        (should-not (harness-ui-pending-record "s-1" "p-fetched"))
        (should-not (string-match-p "Proceed?" (buffer-string)))))))

(ert-deftest harness-ui-workspace-follows-pending-and-status-events ()
  "session/pending-changed fills the store and the status before a fetch."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-test-render)
      (harness-ui-workspace--on-event
       'session/pending-changed
       (list "s-1" (list (list :id "p-event" :kind "question"
                               :payload (list :question "Carry on?")))))
      (should (harness-ui-pending-record "s-1" "p-event"))
      (should (string-match-p "Carry on?" (buffer-string)))
      (should (equal "blocked"
                     (plist-get (car (plist-get harness-ui-workspace--data :threads))
                                :episode-status)))
      (harness-ui-workspace--on-event 'session/status (list "s-1" 'running))
      (should (equal "running"
                     (plist-get (car (plist-get harness-ui-workspace--data :threads))
                                :episode-status))))))

(ert-deftest harness-ui-workspace-send-answers-a-question ()
  "The box answers a waiting question, as a chat's does, not a new prompt."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-test-render)
      (harness-ui-workspace-test-question)
      (harness-ui-workspace--render)
      (let ((inhibit-read-only t))
        (harness-compose-insert "sqlite"))
      (let (calls)
        (cl-letf (((symbol-function 'harness-ui-call)
                   (lambda (method params callback &optional _on-error)
                     (push (list method params) calls)
                     (funcall callback nil)))
                  ((symbol-function 'harness-compose-fetch-completions) #'ignore))
          (harness-ui-workspace-send))
        (should (equal "_harness/question/answer" (caar calls)))
        (should (equal "q-1" (plist-get (cadar calls) :pid)))
        (should (equal "sqlite" (plist-get (cadar calls) :answer)))
        (should-not (cl-find "_harness/workspace/prompt" calls :key #'car :test #'equal))
        (should-not (harness-ui-pending-record "s-1" "q-1"))))))

(ert-deftest harness-ui-workspace-send-composes-a-multiple-answer ()
  "Options ticked and the words in the box are one answer."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-test-render)
      (harness-ui-workspace-test-question "q-multi" "s-1" "Pick storage"
                                          '("sqlite" "postgres") t)
      (harness-ui-pending-toggle-option "s-1" "q-multi" 1)
      (harness-ui-workspace--render)
      (let ((inhibit-read-only t))
        (harness-compose-insert "and a backup"))
      (let (calls)
        (cl-letf (((symbol-function 'harness-ui-call)
                   (lambda (method params callback &optional _on-error)
                     (push (list method params) calls)
                     (funcall callback nil)))
                  ((symbol-function 'harness-compose-fetch-completions) #'ignore))
          (harness-ui-workspace-send))
        (should (equal "postgres\nand a backup"
                       (plist-get (cadar calls) :answer)))))))
(ert-deftest harness-ui-workspace-computer-shows-the-real-box ()
  "The computer page names the backend, the screen and the VNC endpoint."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-computer-mode)
      (setq harness-ui-workspace-computer--workspace "w-1"
            harness-ui-workspace-computer--data
            (list :name "Home" :state "running" :running t :available t
                  :backend "local" :isolation "local display and process"
                  :control "agent" :display "127.0.0.1:90"
                  :width 1280 :height 800
                  :url "http://127.0.0.1:6080/vnc_lite.html"
                  :socket "ws://127.0.0.1:6080/websockify"))
      (harness-ui-workspace-computer--render)
      (let ((text (buffer-string)))
        (should (string-match-p "Workspace computer  ·  Home  ·  Live" text))
        (should (string-match-p "Backend  local" text))
        (should (string-match-p "Control  Agent" text))
        (should (string-match-p "Display  127.0.0.1:90" text))
        (should (string-match-p "Screen  1280 × 800" text))
        (should (string-match-p "VNC  http://127.0.0.1:6080/vnc_lite.html" text))
        (should (string-match-p "Socket  ws://127.0.0.1:6080/websockify" text))
        (dolist (label '("Startup" "Stop" "Restart" "Takeover" "Control return"
                         "VNC page" "Screenshot" "Refresh"))
          (should (string-match-p label text)))
        (should-not (string-match-p "Preview\\|staged\\|mock" text)))
      (goto-char (point-min))
      (dolist (pair '(("Startup" . "workspace computer startup")
                      ("Stop" . "workspace computer stop")
                      ("Restart" . "workspace computer restart")
                      ("Takeover" . "reviewer control")
                      ("Control return" . "agent control")
                      ("VNC page" . "noVNC page")
                      ("Screenshot" . "current screen picture")
                      ("Refresh" . "computer refresh")))
        (goto-char (point-min))
        (search-forward (car pair))
        (should (equal (cdr pair)
                       (get-text-property (1- (point)) 'help-echo)))))))

(ert-deftest harness-ui-workspace-computer-off-says-why ()
  "A computer that cannot run names what is missing, never a picture."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-computer-mode)
      (setq harness-ui-workspace-computer--workspace "w-1"
            harness-ui-workspace-computer--data
            (list :name "Home" :state "failed" :running :false :available :false
                  :backend "local" :control "agent"
                  :reason '(:code "box-tools-missing"
                            :text "workspace computer tools missing: Xvfb x11vnc")
                  :missing '(Xvfb x11vnc)))
      (harness-ui-workspace-computer--render)
      (let ((text (buffer-string)))
        (should (string-match-p "Workspace computer  ·  Home  ·  Unavailable" text))
        (should (string-match-p "Reason  workspace computer tools missing: Xvfb x11vnc" text))
        (should (string-match-p "Missing  Xvfb x11vnc" text))
        (should-not (string-match-p "VNC  http" text))
        (should-not (string-match-p "Preview\\|staged\\|mock" text)))
      (let ((error (should-error (harness-ui-workspace-computer-open-vnc)
                                :type 'user-error)))
        (should (equal "No VNC page · computer off"
                       (error-message-string error)))))))

(defun harness-ui-workspace-test-cache-session ()
  "Put the fixture's live episode in the session cache, with its figures."
  (puthash "s-1" (list :id "s-1" :model "demo:scripted" :thinking "medium"
                       :permission-mode "auto" :status "idle"
                       :context-window 200000
                       :usage (list :context 12345 :output 500 :cost 0.42))
           harness-ui--sessions))

(ert-deftest harness-ui-workspace-settings-line-names-the-settings ()
  "The line under the box names the model, thinking level and permission mode.
It is the same settings line a chat draws, so a workspace episode and a
chat session say what they run with in the same words, and the episode's
context and cost stand beside them."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-test-cache-session)
      (harness-ui-workspace-test-render)
      (goto-char (point-max))
      (should (equal " scripted (Demo) · … medium · Auto · interactive   12.3k/200k · $0.420"
                     (buffer-substring-no-properties
                      (line-beginning-position) (line-end-position))))
      (goto-char (point-min))
      (search-forward "scripted (Demo)")
      (should (equal "Model of this thread" (get-text-property (1- (point)) 'help-echo)))
      (search-forward "medium")
      (should (equal "Thinking level of this thread"
                     (get-text-property (1- (point)) 'help-echo)))
      (search-forward "Auto")
      (should (equal "Permission mode of this thread"
                     (get-text-property (1- (point)) 'help-echo)))
      (should-not (string-match-p "non-interactive" (buffer-string))))))

(ert-deftest harness-ui-workspace-settings-line-shows-the-workspace-defaults ()
  "A thread with no episode names the defaults the next one starts with."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-test-cache-session)
      (harness-ui-workspace-test-render)
      (harness-ui-workspace--select-thread "th-2")
      (goto-char (point-max))
      (let ((line (buffer-substring-no-properties
                   (line-beginning-position) (line-end-position))))
        ;; The parked thread has no live episode: its defaults, and no
        ;; figures of an episode that does not exist.
        (should (equal " scripted (Demo) · … medium · Auto · interactive" line)))
      (goto-char (point-min))
      (search-forward "scripted (Demo)")
      (should (equal "Model of this workspace"
                     (get-text-property (1- (point)) 'help-echo)))
      (should (equal (list (list :model "demo:scripted" :thinking "medium"
                                 :permission-mode "auto" :non-interactive nil)
                           (nth 1 (harness-ui-workspace--setting-target))
                           "this workspace")
                     (harness-ui-workspace--setting-target))))))

(ert-deftest harness-ui-workspace-leaves-point-in-the-box ()
  "A redraw leaves point in the compose box, not after the settings line."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-test-render)
      (should (harness-compose-in-p))
      (should (<= (point) harness-compose-end)))))

(ert-deftest harness-ui-workspace-settings-line-with-no-thread ()
  "A workspace with no thread yet still names the model it would start on."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-mode)
      (setq harness-ui-workspace--id "w-1"
            harness-ui-workspace--state 'ready
            harness-ui-workspace--data (list :id "w-1" :name "Home"
                                             :root "/tmp/workspace/"
                                             :threads nil
                                             :model "demo:scripted"
                                             :permission-mode "auto")
            harness-ui-workspace--entries nil)
      (cl-letf (((symbol-function 'harness-compose-fetch-completions) #'ignore))
        (harness-ui-workspace--render))
      (goto-char (point-max))
      (should (equal " scripted (Demo) · … default · Auto · interactive"
                     (buffer-substring-no-properties
                      (line-beginning-position) (line-end-position))))
      (should (equal "this workspace"
                     (nth 2 (harness-ui-workspace--setting-target)))))))

(ert-deftest harness-ui-workspace-says-what-the-running-turn-does ()
  "The header and the thread row say the running turn's activity, not a time.
The words are the chat's, and a turn that is waiting for the model says
so before the first token arrives."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-test-render)
      (harness-ui-workspace--change-thread
       "th-1" (list :activity (list :phase "waiting" :since 1.0)))
      (harness-ui-workspace--render)
        (should (string-match-p "Thread · Kitchen renovation · Running · Waiting for the model…"
                                (buffer-string)))
        (should (string-match-p "Kitchen renovation  Waiting for the model…"
                                (buffer-string)))
        (goto-char (point-min))
        (should (equal (concat "Workspace · Home   Thread · Kitchen renovation · Running · "
                               "Waiting for the model…   Knowledge · unavailable   Computer · off   "
                               "Tasks New thread Episode Stop Refresh Graph Workspace computer Resources")
                       (buffer-substring-no-properties
                        (line-beginning-position) (line-end-position)))))))

(ert-deftest harness-ui-workspace-running-turn-says-so-above-the-box ()
  "The line above the box says what the selected turn does.
The header and the thread rail scroll away with a long timeline; the
line above the box, where the person types, does not."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-test-render)
      (harness-ui-workspace--change-thread
       "th-1" (list :episode-status "running"
                    :activity (list :phase "waiting" :since 1.0)))
      (harness-ui-workspace--render)
      ;; The last line saying it is the one above the box, not the header's.
      (goto-char (point-max))
      (search-backward "Waiting for the model…")
      (should (equal " Waiting for the model…"
                     (buffer-substring-no-properties
                      (line-beginning-position) (line-end-position))))
      (should-not (harness-compose-in-p))
      ;; It sits above the compose area; the settings line follows the box.
      (let ((activity (point))
            (box (save-excursion (goto-char (point-max))
                                 (search-backward "❯") (point)))
            (settings (save-excursion (goto-char (point-max))
                                      (search-backward " scripted (Demo)") (point))))
        (should (< activity box))
        (should (< box settings)))
      ;; A running turn without an activity says it works; an idle one is quiet.
      (harness-ui-workspace--change-thread
       "th-1" (list :episode-status "running" :activity nil))
      (harness-ui-workspace--render)
      (should (string-match-p " Working…\n" (buffer-string)))
      (harness-ui-workspace--change-thread
       "th-1" (list :episode-status "idle" :activity nil))
      (harness-ui-workspace--render)
      (should-not (string-match-p "Waiting for the model…" (buffer-string)))
      (should-not (string-match-p "Working…" (buffer-string))))))

(ert-deftest harness-ui-workspace-activity-follows-the-turn ()
  "An activity update says what the turn does now; a session update its model."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-test-render)
      (harness-ui-workspace--on-update
       "s-1" (list :sessionUpdate "_harness/activity"
                   :activity (list :phase "tool" :tool "read_file"
                                   :title "Read file: x.el" :since 2.0)))
      (should (string-match-p "Running Read file: x.el…" (buffer-string)))
      (harness-ui-workspace--on-update
       "s-1" (list :sessionUpdate "_harness/activity" :activity nil))
      (should-not (string-match-p "Running Read file" (buffer-string)))
      ;; A setting changes the thread's own values, so the line follows it.
      (harness-ui-workspace--on-update
       "s-1" (list :sessionUpdate "_harness/session"
                   :session (list :id "s-1" :model "other:model" :thinking "high"
                                  :permission-mode "yolo" :non-interactive t)))
      (should (string-match-p "model (Other)" (buffer-string)))
      (should (string-match-p "YOLO" (buffer-string)))
      (should (string-match-p "non-interactive" (buffer-string))))))

(ert-deftest harness-ui-workspace-send-shows-the-model-loading ()
  "Sending marks the thread running and waiting for the model at once."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-test-render)
      (let ((inhibit-read-only t))
        (harness-compose-insert "Please remember the matte tile."))
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (_method _params callback &optional _on-error)
                   (funcall callback nil)))
                ((symbol-function 'harness-compose-fetch-completions) #'ignore))
        (harness-ui-workspace-send))
      (should (string-match-p "Waiting for the model…" (buffer-string)))
      (let ((thread (car (plist-get harness-ui-workspace--data :threads))))
        (should (equal "running" (plist-get thread :episode-status)))
        (should (equal "waiting" (plist-get (plist-get thread :activity) :phase)))))))


(defun harness-ui-workspace-test-graph-data (status)
  "Return a graph answer for the explorer tests, at STATUS."
  (append
   (list :workspace "w-1" :workspace-name "Home" :status status
         :page-name "Threads/Kitchen renovation"
         :thread "Kitchen renovation" :thread-id "th-1"
         :page (list :title "Threads/Kitchen renovation"
                     :name "Threads/Kitchen renovation"
                     :properties (list (cons "thread-id" "th-1")
                                       (cons "workspace-status" "active"))
                     :tags (list "Thread") :links (list "Stone Co"))
         :links (list "Stone Co") :count 1)
   (when (equal status "ready")
     (list :blocks (list (list :id "b-1" :line 3 :indent 0
                               :text "The grout is warm grey."
                               :properties (list (cons "id" "b-1")
                                                 (cons "workspace" "Home")
                                                 (cons "thread" "[[Threads/Kitchen renovation]]"))
                               :tags (list "Memory" "Decision")
                               :links (list "Stone Co")
                               :created 1794161220000
                               :page "Threads/Kitchen renovation"))
           :backlinks (list (list :id "j-1" :page "2026-11-08"
                                  :text "user: The tile is matte.")
                            (list :id "j-2" :page "2026-11-08"
                                  :text "assistant: Noted."))))))


;;;; The graph explorer

(defun harness-ui-workspace-test-graph-render (view data &optional stack error)
  "Render the graph buffer with VIEW, DATA, STACK and ERROR.
Return its text, text properties and all, so tooltips are kept."
  (with-temp-buffer
    (harness-ui-workspace-graph-mode)
    (setq buffer-read-only nil
          harness-ui-workspace-graph--id "w-1"
          harness-ui-workspace-graph--name "Home"
          harness-ui-workspace-graph--thread "th-1"
          harness-ui-workspace-graph--view view
          harness-ui-workspace-graph--stack stack
          harness-ui-workspace-graph--error error
          harness-ui-workspace-graph--data data)
    (harness-ui-workspace-graph--render)
    (buffer-string)))

(defun harness-ui-workspace-test-graph-time ()
  "Return the note fixture's created time, as the buffer shows it."
  (format-time-string "%Y-%m-%d %H:%M"
                      (seconds-to-time (/ 1794161220000 1000.0))))

(ert-deftest harness-ui-workspace-graph-shows-the-thread ()
  "The graph buffer's thread view, its exact words and its tooltips."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (insert (harness-ui-workspace-test-graph-render
               '(:kind thread)
               (harness-ui-workspace-test-graph-data "ready")))
      (should (equal
               (concat
                "Graph · Home   Thread · Kitchen renovation   Logseq · ready   "
                "Refresh Workspace\n"
                "\n"
                "Page\n"
                "  Name  Threads/Kitchen renovation\n"
                "  Nodes  1\n"
                "  Tags  Thread\n"
                "  Properties\n"
                "    thread-id  th-1\n"
                "    workspace-status  active\n"
                "  Links  Stone Co\n"
                "\n"
                "Nodes\n"
                "Note · " (harness-ui-workspace-test-graph-time) "\n"
                "  The grout is warm grey.\n"
                "  Tags  Memory, Decision\n"
                "  Links  Stone Co\n"
                "  Properties\n"
                "    id  b-1\n"
                "    workspace  Home\n"
                "    thread  [[Threads/Kitchen renovation]]\n"
                "\n"
                "Backlinks\n"
                "  2026-11-08  user: The tile is matte.\n"
                "  2026-11-08  assistant: Noted.\n"
                "\n"
                "g · refresh   RET · open   q · bury\n")
               (buffer-string)))
      (goto-char (point-min))
      (search-forward "Refresh")
      (should (equal "Read the graph again" (get-text-property (1- (point)) 'help-echo)))
      (search-forward "Workspace")
      (should (equal "The workspace chat" (get-text-property (1- (point)) 'help-echo)))
      (search-forward "Note")
      (should (equal "The node in the graph" (get-text-property (1- (point)) 'help-echo)))
      (search-forward "Stone Co")
      (should (equal "The page in the graph" (get-text-property (1- (point)) 'help-echo))))))

(ert-deftest harness-ui-workspace-graph-opens-a-node ()
  "The graph buffer's node view: the node, its page and its children."
  (harness-ui-workspace-test-with
    (let ((data (harness-ui-workspace-test-graph-data "ready")))
      (with-temp-buffer
        (insert (harness-ui-workspace-test-graph-render
                 '(:kind node :id "b-1")
                 (append data
                         (list :block (car (plist-get data :blocks))
                               :node (car (plist-get data :blocks))
                               :children (list (list :id "b-2" :line 4 :indent 2
                                                     :text "A child note."
                                                     :properties nil :tags nil :links nil
                                                     :created nil
                                                     :page "Threads/Kitchen renovation"))))
                 '((:kind thread))))
        (should (equal
                 (concat
                  "Graph · Home   Node · b-1   Logseq · ready   Refresh Back Workspace\n"
                  "\n"
                  "Node\n"
                  "  Role  Note\n"
                  "  Time  " (harness-ui-workspace-test-graph-time) "\n"
                  "  Text  The grout is warm grey.\n"
                  "  Page  Threads/Kitchen renovation\n"
                  "  Tags  Memory, Decision\n"
                  "  Links  Stone Co\n"
                  "  Properties\n"
                "    id  b-1\n"
                "    workspace  Home\n"
                "    thread  [[Threads/Kitchen renovation]]\n"
                  "\n"
                  "Children\n"
                  "Block\n"
                  "  A child note.\n"
                  "\n"
                  "g · refresh   RET · open   b · back   q · bury\n")
                 (buffer-string)))
        (goto-char (point-min))
        (search-forward "Back")
        (should (equal "The node or page before this one"
                       (get-text-property (1- (point)) 'help-echo)))))))

(ert-deftest harness-ui-workspace-graph-opens-a-page ()
  "The graph buffer's page view, a page not there, and an absent graph."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (insert (harness-ui-workspace-test-graph-render
               '(:kind page :name "Stone Co")
               (list :workspace "w-1" :workspace-name "Home" :status "ready" :why nil
                     :page-name "Stone Co"
                     :page (list :title "Stone Co" :name "Stone Co"
                                 :properties nil :tags (list "People") :links nil)
                     :blocks (list (list :id "b-3" :line 1 :indent 0 :text "The stonemason."
                                         :properties nil :tags nil :links nil
                                         :created nil :page "Stone Co"))
                     :backlinks nil)))
      (should (equal
               (concat
                "Graph · Home   Page · Stone Co   Logseq · ready   Refresh Workspace\n"
                "\n"
                "Page\n"
                "  Name  Stone Co\n"
                "  Title  Stone Co\n"
                "  Tags  People\n"
                "\n"
                "Nodes\n"
                "Block\n"
                "  The stonemason.\n"
                "\n"
                "Backlinks\n"
                "  No backlinks\n"
                "\n"
                "g · refresh   RET · open   q · bury\n")
               (buffer-string))))
    (with-temp-buffer
      (insert (harness-ui-workspace-test-graph-render
               '(:kind page :name "Nowhere")
               (harness-ui-workspace-test-graph-data "missing")))
      (should (equal
               (concat
                "Graph · Home   Page · Nowhere   Logseq · not found   Refresh Workspace\n"
                "\n"
                "Page\n"
                "  No page\n"
                "\n"
                "Nodes\n"
                "  No nodes\n"
                "\n"
                "Backlinks\n"
                "  No backlinks\n"
                "\n"
                "g · refresh   RET · open   q · bury\n")
               (buffer-string))))
    (with-temp-buffer
      (insert (harness-ui-workspace-test-graph-render
               '(:kind thread)
               (plist-put (harness-ui-workspace-test-graph-data "unavailable")
                          :why "no-page-directory")))
      (should (equal
               (concat
                "Graph · Home   Thread · Kitchen renovation   Logseq · unavailable   "
                "Refresh Workspace\n"
                "\n"
                "Page\n"
                "  No graph\n"
                "  no-page-directory\n"
                "\n"
                "g · refresh   RET · open   q · bury\n")
               (buffer-string))))))

(ert-deftest harness-ui-workspace-graph-says-what-is-not-there ()
  "A node that is gone says so; a missing graph has no page to draw."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (insert (harness-ui-workspace-test-graph-render
               '(:kind node :id "n-gone")
               (append (harness-ui-workspace-test-graph-data "ready")
                       (list :block nil :node nil :children nil))
               '((:kind thread))))
      (should (string-match-p "Node\n  No node\n" (buffer-string))))
    (with-temp-buffer
      (insert (harness-ui-workspace-test-graph-render
               '(:kind thread)
               (harness-ui-workspace-test-graph-data "missing")))
      (should (string-match-p "Logseq · not found" (buffer-string)))
      (should (string-match-p "Page\n  No page\n" (buffer-string))))
    (with-temp-buffer
      (insert (harness-ui-workspace-test-graph-render
               '(:kind thread)
               (harness-ui-workspace-test-graph-data "ready")
               nil "No Logseq CLI"))
      (should (string-match-p "\nNo Logseq CLI\n" (buffer-string))))))

(ert-deftest harness-ui-workspace-graph-keys-and-refusals ()
  "The graph buffer is read-only, keeps its keys, and refuses what it cannot do."
  (harness-ui-workspace-test-with
    (should (eq 'harness-ui-workspace-graph
                (lookup-key harness-ui-workspace-mode-map (kbd "C-c w l"))))
    (with-temp-buffer
      (harness-ui-workspace-graph-mode)
      (should (equal "Workspace Graph" mode-name))
      (should buffer-read-only)
      (should (eq 'harness-ui-workspace-graph-refresh
                  (lookup-key harness-ui-workspace-graph-mode-map (kbd "g"))))
      (should (eq 'harness-ui-workspace-graph-open
                  (lookup-key harness-ui-workspace-graph-mode-map (kbd "RET"))))
      (should (eq 'harness-ui-workspace-graph-back
                  (lookup-key harness-ui-workspace-graph-mode-map (kbd "b"))))
      (should (eq 'harness-ui-bury
                  (lookup-key harness-ui-workspace-graph-mode-map (kbd "q"))))
      (should-error (harness-ui-workspace-graph-open) :type 'user-error)
      (should-error (harness-ui-workspace-graph-back) :type 'user-error)
      (should-error (harness-ui-workspace-graph-workspace) :type 'user-error))
    (let ((harness-ui-workspace-graph--last-id nil))
      (should-error (harness-ui-workspace-graph) :type 'user-error))))

(ert-deftest harness-ui-workspace-graph-follows-a-node-and-a-page ()
  "RET at a node or a link opens it, and keeps the view before it."
  (harness-ui-workspace-test-with
    (let ((data (harness-ui-workspace-test-graph-data "ready")))
      (with-temp-buffer
        (harness-ui-workspace-graph-mode)
        (setq buffer-read-only nil
              harness-ui-workspace-graph--id "w-1"
              harness-ui-workspace-graph--name "Home"
              harness-ui-workspace-graph--view '(:kind thread)
              harness-ui-workspace-graph--data data)
        (harness-ui-workspace-graph--render)
        (goto-char (point-min))
        (search-forward "Stone Co")
        (cl-letf (((symbol-function 'harness-ui-workspace-graph--fetch) #'ignore))
          (harness-ui-workspace-graph-open))
        (should (equal '(:kind page :name "Stone Co")
                       harness-ui-workspace-graph--view))
        (should (equal '((:kind thread)) harness-ui-workspace-graph--stack))
        (setq harness-ui-workspace-graph--view '(:kind thread)
              harness-ui-workspace-graph--stack nil
              harness-ui-workspace-graph--data data)
        (harness-ui-workspace-graph--render)
        (goto-char (point-min))
        (search-forward "Note")
        (cl-letf (((symbol-function 'harness-ui-workspace-graph--fetch) #'ignore))
          (harness-ui-workspace-graph-open))
        (should (equal '(:kind node :id "b-1")
                       harness-ui-workspace-graph--view))
        (should (equal '((:kind thread)) harness-ui-workspace-graph--stack))))))

;;;; Typing in the compose box

;; The box's letters must type.  A sparse major mode map that keeps
;; `special-mode-map' as its parent would bind them to `undefined'
;; (its `[remap self-insert-command]'), and the key would report
;; "undefined" instead of inserting: the box's keys are
;; `harness-compose-map', and the tests below drive the real command
;; loop, as a keyboard does, rather than calling `insert'.

(defun harness-ui-workspace-test--type (keys)
  "Type KEYS in the selected window's buffer, through the command loop.
KEYS is a string of characters as typed, a space included: `kbd'
would read a space as the separator between key descriptions, so
only named keys go through it, at the call site."
  (execute-kbd-macro keys))

(defmacro harness-ui-workspace-test-typing (&rest body)
  "Show a rendered workspace in the selected window, then run BODY.
The command loop dispatches to the selected window's buffer, so the
workspace has to be the one it shows."
  (declare (indent 0))
  `(harness-ui-workspace-test-with
     (let ((buf (generate-new-buffer " *workspace typing*")))
       (unwind-protect
           (save-window-excursion
             (set-window-buffer (selected-window) buf)
             (with-current-buffer buf
               (harness-ui-workspace-test-render)
               (goto-char harness-compose-end)
               ,@body))
         (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest harness-ui-workspace-compose-letters-type ()
  "Every printable key types into an empty box instead of signalling."
  (harness-ui-workspace-test-typing
    ;; A letter, the letters that are a board's or a view's elsewhere,
    ;; space, and the punctuation that opens a help page in a view.
    (harness-ui-workspace-test--type "abc")
    (harness-ui-workspace-test--type "q")
    (harness-ui-workspace-test--type "g")
    (harness-ui-workspace-test--type "?")
    (harness-ui-workspace-test--type " ")
    (harness-ui-workspace-test--type ",.!")
    (should (equal "abcqg? ,.!" (harness-compose-text)))
    (should (harness-compose-in-p))))

(ert-deftest harness-ui-workspace-compose-letters-type-into-a-draft ()
  "Letters append to a draft the box already holds, and it survives."
  (harness-ui-workspace-test-typing
    (let ((inhibit-read-only t))
      (harness-compose-insert "Draft"))
    (goto-char harness-compose-end)
    (harness-ui-workspace-test--type " more")
    (should (equal "Draft more" (harness-compose-text)))))

(ert-deftest harness-ui-workspace-compose-newline-keeps-lines ()
  "RET opens a line in the box, and the letters go on typing."
  (harness-ui-workspace-test-typing
    (harness-ui-workspace-test--type "one")
    (harness-ui-workspace-test--type (kbd "RET"))
    (harness-ui-workspace-test--type "two")
    (should (equal "one\ntwo" (harness-compose-text)))))

(ert-deftest harness-ui-workspace-compose-types-from-outside-the-box ()
  "A letter typed outside the box still types into it."
  (harness-ui-workspace-test-typing
    (goto-char (point-min))
    (should-not (harness-compose-in-p))
    (harness-ui-workspace-test--type "away")
    (should (equal "away" (harness-compose-text)))
    (should (harness-compose-in-p))))

(ert-deftest harness-ui-workspace-compose-keys-are-the-box-keys ()
  "The mode's map takes its letters from the box's map, not special-mode's."
  (harness-ui-workspace-test-with
    (with-temp-buffer
      (harness-ui-workspace-mode)
      (should (eq harness-compose-map (keymap-parent harness-ui-workspace-mode-map)))
      (should-not (eq special-mode-map (keymap-parent harness-ui-workspace-mode-map)))
      ;; The chords the workspace adds still act on the workspace.
      (should (eq 'harness-ui-workspace-send (key-binding (kbd "C-c C-c"))))
      (should (eq 'harness-ui-workspace-refresh (key-binding (kbd "C-c w g"))))
      (should (eq 'harness-compose-newline (key-binding (kbd "RET")))))))

(ert-deftest harness-ui-workspace-compose-redraw-keeps-the-draft ()
  "A redraw keeps the draft and point, so typing goes on where it was."
  (harness-ui-workspace-test-typing
    (harness-ui-workspace-test--type "matte tile")
    (let ((before (point)))
      (cl-letf (((symbol-function 'harness-compose-fetch-completions) #'ignore))
        (harness-ui-workspace--render))
      (should (equal "matte tile" (harness-compose-text)))
      (should (= before (point)))
      (harness-ui-workspace-test--type "!")
      (should (equal "matte tile!" (harness-compose-text))))))

(ert-deftest harness-ui-workspace-compose-send-keeps-its-key ()
  "C-c C-c sends what was typed, with no insert call in between."
  (harness-ui-workspace-test-typing
    (let (sent)
      (harness-ui-workspace-test--type "Ship it")
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (method params callback &optional _on-error)
                   (push (list method params) sent)
                   (funcall callback nil)))
                ((symbol-function 'harness-compose-fetch-completions) #'ignore))
        (harness-ui-workspace-test--type (kbd "C-c C-c")))
      (should (equal "_harness/workspace/prompt" (caar sent)))
      (should (string-match-p "Ship it" (plist-get (cadar sent) :text))))))
