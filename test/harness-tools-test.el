;;; harness-tools-test.el --- Tests for the tool registry  -*- lexical-binding: t; -*-

;;; Commentary:

;; A tool has two names: the one the model calls it by (read_file) and
;; its label, the one people read (Read file).  A tool must declare its
;; label, and a call is titled with it: "Read file: x.el".

;;; Code:

(require 'harness-test-helpers)

(defvar harness-tools)

(defmacro harness-tools-test-with (&rest body)
  "Run BODY with the tools module on a fresh bus and an empty registry."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (harness-test-load-module 'tools)
     (clrhash harness-tools)
     ,@body))

(ert-deftest harness-tools-label-is-required ()
  "A tool must say what people call it."
  (harness-tools-test-with
    (should-error (harness-define-tool "t_nameless" :handler #'ignore))
    (should-error (harness-define-tool "t_blank" :label "  " :handler #'ignore))
    (should-not (harness-tool-get "t_nameless"))
    (should-not (harness-tool-get "t_blank"))
    (harness-define-tool "t_named" :label " Named tool " :handler #'ignore)
    (should (equal "Named tool" (harness-tools-label "t_named")))
    ;; One nobody registered, as a model may make up, goes by its name.
    (should (equal "t_unknown" (harness-tools-label "t_unknown")))))

(ert-deftest harness-tools-specs-carry-the-label ()
  "UIs learn the labels from the specs `tools/list' and `tools/get' return."
  (harness-tools-test-with
    (harness-define-tool "t_read" :label "Read thing" :kind 'read :handler #'ignore)
    (should (equal "Read thing" (plist-get (harness-call 'tools/get "t_read") :label)))
    (should (equal '("Read thing") (mapcar (lambda (s) (plist-get s :label)) (harness-call 'tools/list))))))

(ert-deftest harness-tools-titles-name-the-tool-by-its-label ()
  "A call's title is the tool's label, then what the call is about."
  (harness-tools-test-with
    (harness-define-tool "t_read" :label "Read thing" :subject (lambda (input) (plist-get input :path))
                         :handler #'ignore)
    (harness-define-tool "t_plain" :label "Plain" :handler #'ignore)
    (harness-define-tool "t_silent" :label "Silent" :subject #'ignore :handler #'ignore)
    (harness-define-tool "t_broken" :label "Broken" :subject (lambda (_) (error "Oops")) :handler #'ignore)
    (should (equal "Read thing: a.el" (harness-tool-title "t_read" '(:path "a.el"))))
    ;; About nothing in particular: the label alone.
    (should (equal "Read thing" (harness-tool-title "t_read" nil)))
    (should (equal "Silent" (harness-tool-title "t_silent" '(:text "not this"))))
    ;; Without a subject function, or when it fails: the first line of the first string.
    (should (equal "Plain: first" (harness-tool-title "t_plain" '(:n 1 :text "first\nsecond"))))
    (should (equal "Plain" (harness-tool-title "t_plain" '(:n 1))))
    (should (equal "Broken: x" (harness-tool-title "t_broken" '(:text "x"))))
    ;; A tool nobody registered goes by its name.
    (should (equal "t_unknown: x" (harness-tool-title "t_unknown" '(:text "x"))))))

(ert-deftest harness-tools-survive-records-from-before-labels ()
  "A tool registered before tools had labels, its record a slot short, still works.
Its module may fail to load again in a reload; it goes by its name."
  (harness-tools-test-with
    (puthash "t_old" (record 'harness-tool "t_old" "An old tool." '(:type "object") #'ignore 'read nil nil
                             (lambda (input) (format "t_old %s" (plist-get input :path))) 'old nil)
             harness-tools)
    (should (equal "t_old" (harness-tools-label "t_old")))
    (should (equal '("t_old") (mapcar (lambda (s) (plist-get s :label)) (harness-call 'tools/list))))
    (should (eq 'read (plist-get (harness-call 'tools/get "t_old") :kind)))
    (should (equal "t_old: t_old a.el" (harness-tool-title "t_old" '(:path "a.el"))))))

(ert-deftest harness-tools-reload-loads-the-registry-first ()
  "A reload loads harness.el first, which loads the tool registry before the
modules that define tools with it, though they sort before it."
  (harness-tools-test-with
    (let ((current (symbol-function 'harness-define-tool)))
      (unwind-protect
          (progn
            ;; As if the registry loaded were older than the modules reloading.
            (fset 'harness-define-tool (lambda (&rest _) (error "An old registry")))
            (load (expand-file-name "harness.el" harness-test-root) nil 'nomessage)
            (harness-define-tool "t_new" :label "New tool" :handler #'ignore)
            (should (equal "New tool" (harness-tools-label "t_new"))))
        (unless (equal "New tool" (harness-tools-label "t_new"))
          (fset 'harness-define-tool current))))))

(ert-deftest harness-tools-every-tool-has-a-label-for-people ()
  "Every tool the harness ships declares a label, written for people.
That is words, capitalised like a name, and not the tool's own name."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (dolist (m '(store project config provider provider-demo tools))
      (harness-test-load-module m))
    ;; Only the tools of the modules, not those other tests made up.
    (clrhash harness-tools)
    (dolist (m '(session agent tools-fs tools-shell tools-ssh tools-emacs tools-web tools-agent tools-question tools-plan tools-todo tools-session-info skills perms
                 tasks tools-sessions merge notifications tools-notify))
      (harness-test-load-module m))
    (let ((names (mapcar (lambda (s) (plist-get s :name)) (harness-call 'tools/list))))
      (should (member "read_file" names))
      (should (member "ssh" names))
      (should (member "request_directory_access" names))
      (should (member "merge_done" names))
      (should (member "notify" names))
      (dolist (name names)
        (let ((label (harness-tools-label name)))
          (should (stringp label))
          (should-not (equal name label))
          (should (string-match-p "\\`[[:upper:]][^_]*\\'" label))))
      ;; No two tools share a label: people could not tell them apart.
      (should (= (length names) (length (delete-dups (mapcar #'harness-tools-label names))))))))

(ert-deftest harness-tools-schemas-never-send-required-null ()
  "A tool schema never puts JSON null where the schema needs an array.
An empty `:required' is an empty list, which the JSON convention encodes
as null; a provider refuses the whole request then (null is not of type
array), as OpenAI did for hand_in, whose evidence item requires no key."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (dolist (m '(store project config provider provider-demo tools))
      (harness-test-load-module m))
    (clrhash harness-tools)
    (dolist (m '(session agent skills perms tasks merge notifications))
      (harness-test-load-module m))
    ;; Every tools-* module, so a new one cannot be left out by hand,
    ;; as tools-dev was when open_harness left Claude Code with no tools;
    ;; those of this repository's own plugins too, where tools-dev is now.
    (dolist (dir (cons (expand-file-name "lisp/modules" harness-test-root)
                       (harness-test-plugin-directories)))
      (dolist (file (directory-files dir nil "\\`harness-\\(tools-.*\\)\\.el\\'"))
        (harness-test-load-module (intern (substring file 8 -3)))))
    (let ((specs (harness-call 'tools/list)))
      (should (member "hand_in" (mapcar (lambda (s) (plist-get s :name)) specs)))
      (should (member "open_harness" (mapcar (lambda (s) (plist-get s :name)) specs)))
      (dolist (spec specs)
        (let ((json (harness-json-encode (plist-get spec :schema))))
          (should-not (string-match-p "\"required\":null" json)))))))

(defconst harness-tools-test--reads-kept-in-view
  '("session_wait" "task_wait" "watch_events" "unwatch_events")
  "The tools of kind read whose calls the chat keeps in view, never folded.
A wait says what it waits on in a note under its call while it runs, and
a watch is set to wake the session later: a summary line would hide them.")

(ert-deftest harness-tools-reads-fold-unless-they-wait-or-watch ()
  "A tool that only reads is on the allow list of calls the chat folds into a summary.
The chat folds the calls of the tools that say `:coalescable', so a
read nobody put on the list stands as a line of its own in the middle
of a run, and cuts the run in two.  The tools that wait on sessions,
tasks or events stay in view on purpose, and are named here: a read
that is neither folded nor named fails, so adding one is a decision."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (dolist (m '(store project config provider provider-demo tools))
      (harness-test-load-module m))
    (clrhash harness-tools)
    (dolist (m '(session agent skills perms tasks merge notifications))
      (harness-test-load-module m))
    (dolist (file (directory-files (expand-file-name "lisp/modules" harness-test-root)
                                   nil "\\`harness-\\(tools-.*\\)\\.el\\'"))
      (harness-test-load-module (intern (substring file 8 -3))))
    (let ((reads nil) (not-folded nil) (folded-though-kept nil))
      (dolist (spec (harness-call 'tools/list))
        (when (eq 'read (plist-get spec :kind))
          (let ((name (plist-get spec :name))
                (folds (plist-get spec :coalescable)))
            (push name reads)
            (cond ((member name harness-tools-test--reads-kept-in-view)
                   (when folds (push name folded-though-kept)))
                  ((not folds) (push name not-folded))))))
      ;; The loop met the tools it is about, those named here among them.
      (should (member "read_file" reads))
      (should (member "session_read" reads))
      (dolist (name harness-tools-test--reads-kept-in-view)
        (should (member name reads)))
      (should (equal nil (sort not-folded #'string<)))
      (should (equal nil (sort folded-though-kept #'string<))))))

;; Claude Code 2.1.289 refuses a tools/list holding such a schema, and
;; then offers the model none of the harness's tools.
(ert-deftest harness-tools-registry-drops-empty-required ()
  "An empty `:required' a tool declares, at any depth, never reaches a provider."
  (harness-tools-test-with
    (harness-define-tool "t_optional" :label "Optional" :handler #'ignore
                         :schema '(:type "object"
                                   :properties (:path (:type "string")
                                                :item (:type "object"
                                                       :properties (:x (:type "string"))
                                                       :required ()))
                                   :required ()))
    (harness-define-tool "t_needs" :label "Needs" :handler #'ignore
                         :schema '(:type "object" :properties (:path (:type "string"))
                                   :required ("path")))
    (let ((json (harness-json-encode (plist-get (harness-call 'tools/get "t_optional") :schema))))
      (should-not (string-match-p "required" json))
      (should (string-match-p "\"x\"" json)))
    (should (equal '("path") (plist-get (plist-get (harness-call 'tools/get "t_needs") :schema)
                                        :required)))))

;;;; Notes under running calls

(defvar harness-sessions)
(defvar harness-agent--turns)
(defvar harness-agent--activities)
(declare-function harness-provider-demo--last-user-text "harness-provider-demo")

(defmacro harness-tools-test-with-sessions (&rest body)
  "Run BODY with the tools, session and agent modules on a fresh bus."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-agent--activities)
     (let ((default-directory dir))
       ,@body)))

(defun harness-tools-test-session (&optional plist)
  "Create a demo session with PLIST overrides; return its id."
  (plist-get (apply #'harness-call 'session/create
                    (append plist (list :cwd (harness-test-temp-dir) :model "demo:scripted")))
             :id))

(ert-deftest harness-tools-tail-line ()
  "The last visible line of tool output, without colour or control codes."
  (should (equal "PASS b.test" (harness-tools-tail-line "\e[32mPASS\e[0m a.test\nPASS b.test\n")))
  (should (equal "half" (harness-tools-tail-line "10%\r50%\rhalf")))
  (should (equal "text" (harness-tools-tail-line "text")))
  (should-not (harness-tools-tail-line "  \n \n"))
  (should-not (harness-tools-tail-line nil)))

(ert-deftest harness-tools-session-facts ()
  "The facts line: tokens against the compaction window, turns, steps, tools."
  (harness-tools-test-with-sessions
    (let ((sid (harness-tools-test-session '(:context-window 256000))))
      ;; A session that has done nothing says nothing.
      (should-not (harness-tools-session-facts (harness-call 'session/get sid) 0))
      (harness-call 'session/usage-add sid '(:context 12300 :last-output 0 :turns 3))
      (should (equal "12.3k/256k before compact · 3 turns · 7 steps"
                     (harness-tools-session-facts (harness-call 'session/get sid) 7)))
      ;; Tool calls are counted in the transcript.
      (harness-call 'session/append sid '(:kind tool-call :tool "read_file" :call-id "c1"))
      (should (equal "12.3k/256k before compact · 3 turns · 7 steps · 1 tool call"
                     (harness-tools-session-facts (harness-call 'session/get sid) 7)))
      ;; Without a caller's count, the steps come from the events.
      (harness-emit 'agent/step-started sid 5)
      (should (equal "12.3k/256k before compact · 3 turns · 5 steps · 1 tool call"
                     (harness-tools-session-facts (harness-call 'session/get sid))))
      ;; A turn that starts counts its steps from zero again.
      (harness-emit 'agent/turn-started sid)
      (should (equal "12.3k/256k before compact · 3 turns · 1 tool call"
                     (harness-tools-session-facts (harness-call 'session/get sid)))))))

(ert-deftest harness-tools-session-note ()
  "The note under a call: what the session does, its recap, its facts."
  (harness-tools-test-with-sessions
    (let ((sid (harness-tools-test-session '(:context-window 256000))))
      (harness-call 'session/append sid '(:kind user :content "do the thing"))
      ;; A prompt with nothing after it yet: a sub-agent just started.
      (should (equal "starting" (harness-tools-session-note sid)))
      ;; What a running turn does comes first, with the title it reports.
      (puthash sid (list :phase 'tool :tool "bash" :title "Bash: npm test" :since (float-time))
               harness-agent--activities)
      (harness-call 'session/usage-add sid '(:context 12300 :last-output 0 :turns 2))
      (should (equal "running Bash: npm test\n12.3k/256k before compact · 2 turns"
                     (harness-tools-session-note sid)))
      ;; A title prefixes the note, for a wait over several sessions.
      (should (equal "explorer (45ab12cd): running Bash: npm test\n12.3k/256k before compact · 2 turns"
                     (harness-tools-session-note sid '(:title "explorer (45ab12cd): "))))
      ;; A session that is gone has no note; a call with a title says so.
      (should-not (harness-tools-session-note "nobody"))
      (should (equal "explorer (45ab12cd): gone"
                     (harness-tools-session-note "nobody" '(:title "explorer (45ab12cd): ")))))))

(ert-deftest harness-tools-activity-phrase ()
  "What the running turn does, said in a phrase for the note."
  (harness-tools-test-with-sessions
    (should (equal "running Bash: npm test"
                   (harness-tools--activity-phrase '(:phase tool :tool "bash" :title "Bash: npm test"))))
    (should (equal "checking permission for Bash: npm test"
                   (harness-tools--activity-phrase '(:phase tool :tool "bash" :title "Bash: npm test" :checking t))))
    (should (equal "running Bash: npm test and 2 more"
                   (harness-tools--activity-phrase '(:phase tool :tool "bash" :title "Bash: npm test" :count 3))))
    (should (equal "thinking" (harness-tools--activity-phrase '(:phase thinking))))
    ;; A tool nobody registered goes by its name; a title is used as it is.
    (should (equal "preparing bash" (harness-tools--activity-phrase '(:phase tool-input :tool "bash"))))
    (should (equal "preparing Bash: npm test"
                   (harness-tools--activity-phrase '(:phase tool-input :tool "bash" :title "Bash: npm test"))))
    (should (equal "waiting for the model" (harness-tools--activity-phrase '(:phase waiting))))
    (should (equal "compacting the conversation" (harness-tools--activity-phrase '(:phase compacting))))
    (should (equal "working" (harness-tools--activity-phrase nil)))))

(ert-deftest harness-tools-session-doing ()
  "A session that waits on the user says so; another says what it last did."
  (harness-tools-test-with-sessions
    (let ((sid (harness-tools-test-session)))
      (harness-call 'session/append sid '(:kind user :content "do the thing"))
      (harness-call 'session/append sid '(:kind assistant :content "Done: the widget works."))
      (should (equal "last said: Done: the widget works."
                     (harness-tools-session-doing (harness-call 'session/get sid))))
      ;; A tool call it ran last reads as its title.
      (harness-call 'session/append sid '(:kind tool-call :tool "bash" :call-id "c1" :title "Bash: make test"))
      (should (equal "last ran Bash: make test"
                     (harness-tools-session-doing (harness-call 'session/get sid)))))))

(ert-deftest harness-tools-watch-session-reports-changes ()
  "A watcher hears the note at once, and again only when it changed."
  (harness-tools-test-with-sessions
    (let* ((sid (harness-tools-test-session))
           (seen nil)
           (stop nil))
      (harness-call 'session/append sid '(:kind user :content "go"))
      (setq stop (harness-tools-watch-session sid (lambda (text) (push text seen))))
      (should (equal '("starting") seen))
      (puthash sid (list :phase 'thinking :since (float-time)) harness-agent--activities)
      (harness-emit 'agent/activity-changed sid (gethash sid harness-agent--activities))
      (should (equal '("thinking" "starting") seen))
      ;; Nothing changed: nothing is said again.
      (harness-emit 'agent/activity-changed sid (gethash sid harness-agent--activities))
      (should (equal '("thinking" "starting") seen))
      ;; The tool that asked can stop the watching.
      (funcall stop)
      (puthash sid (list :phase 'writing :since (float-time)) harness-agent--activities)
      (harness-emit 'agent/activity-changed sid (gethash sid harness-agent--activities))
      (should (equal '("thinking" "starting") seen)))))

;;;; Tools of a project's plugins

(ert-deftest harness-tools-a-plugins-tools-are-for-the-sessions-naming-it ()
  "A tool of a plugin module is offered to the sessions that name the module.
The plugin's file decides its module: harness-NAME.el, loaded by a
`require' as a project's .dir-locals.el loads it, not by the harness.
A session gets the tool only when the plugin modules it froze name the
module, and only while the module is ready; any other neither gets it
nor may call it: the call fails as a call of a tool that does not exist
would.  The catalogue lists it, and a tool of the harness's own is
everyone's."
  (harness-tools-test-with
    (let* ((plugin (harness-test-temp-dir))
           (file (expand-file-name "harness-plugtool.el" plugin))
           (plugins '(("in" plugtool) ("out" other)))
           (names (lambda (id) (harness-tools--names (list :id id)))))
      (with-temp-file file
        (insert ";;; -*- lexical-binding: t -*-\n")
        (dolist (form '((require 'harness-tools)
                        (harness-define-tool "plug_tool" :label "Plug tool"
                                             :handler (lambda (_input _ctx) "plugged"))
                        (harness-define-module 'plugtool :requires '(tools))
                        (provide 'harness-plugtool)))
          (prin1 form (current-buffer))
          (insert "\n")))
      (harness-define-tool "plain_tool" :label "Plain tool" :handler (lambda (_input _ctx) "plain"))
      (harness-add-filter 'permission/decide (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
      (harness-register-method 'session/get (lambda (id) (list :id id :cwd plugin)))
      ;; Stands in for the plugins module: the lists the sessions froze.
      (harness-register-method 'plugins/of-session (lambda (id) (cdr (assoc id plugins))))
      (unwind-protect
          (progn
            (require 'harness-plugtool file)
            (should (eq 'plugtool (harness-tool-module (harness-tool-get "plug_tool"))))
            (should (harness-module-plugin-p 'plugtool))
            ;; Not ready yet: nobody gets it.
            (should-not (member "plug_tool" (funcall names "in")))
            (should (harness-module-start 'plugtool))
            (should (member "plug_tool" (funcall names "in")))
            (should-not (member "plug_tool" (funcall names "out")))
            (should-not (member "plug_tool" (funcall names "nobody")))
            (should (member "plain_tool" (funcall names "out")))
            (should (member "plug_tool" (harness-tools--names nil)))
            (should (equal "plugged"
                           (plist-get (harness-test-await
                                       (harness-call 'tools/execute "in" (list :id "c1" :name "plug_tool")))
                                      :content)))
            (let ((result (harness-test-await
                           (harness-call 'tools/execute "out" (list :id "c2" :name "plug_tool")))))
              (should (plist-get result :is-error))
              (should (string-prefix-p "Unknown tool plug_tool" (plist-get result :content))))
            ;; Without the plugins module no session has a plugin's tools.
            (harness-unregister-method 'plugins/of-session)
            (should-not (member "plug_tool" (funcall names "in")))
            (should (member "plain_tool" (funcall names "in"))))
        (setq features (delq 'harness-plugtool features))
        (delete-directory plugin t)))))

;;;; What a tool prints is filtered before anything keeps it

(defvar harness-tools-max-output-chars)

(defun harness-tools-test--run (name &rest input)
  "Run the tool NAME with INPUT, everything allowed, and return its result."
  (harness-add-filter 'permission/decide (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
  (harness-await (harness-call 'tools/execute nil (list :id "c1" :name name :input input)) 10))

(ert-deftest harness-tools-output-filter-runs-before-the-size-guard ()
  "The `tools/output' filter sees the result before it is truncated and saved.
So the file an oversized result is saved to holds the filtered text, and
the filter gets the session and the call it filters for."
  (harness-tools-test-with
    (harness-define-tool "t_loud" :label "Loud" :kind 'read
                         :handler (lambda (input _ctx) (harness-tool-ok (plist-get input :text))))
    (let ((harness-tools-max-output-chars 100)
          (seen nil))
      (harness-add-filter 'tools/output
                          (lambda (result session-id call)
                            (push (list session-id (plist-get call :name)) seen)
                            (plist-put (copy-sequence result) :content
                                       (string-replace "secret" "[x]" (plist-get result :content)))))
      (let* ((text (concat (make-string 300 ?a) " secret " (make-string 300 ?b)))
             (result (harness-tools-test--run "t_loud" :text text))
             (path (plist-get (plist-get result :truncated) :path)))
        (should path)
        (should (equal '((nil "t_loud")) seen))
        (should-not (string-search "secret" (with-temp-buffer (insert-file-contents path) (buffer-string))))
        (should (string-search " [x] " (with-temp-buffer (insert-file-contents path) (buffer-string))))
        ;; The filter ran once; a small result is filtered the same way.
        (should (equal "a [x] b" (plist-get (harness-tools-test--run "t_loud" :text "a secret b") :content)))))))

(ert-deftest harness-tools-output-text-filter-runs-on-progress-and-notes ()
  "The text a tool reports as progress or as a note goes through `tools/output-text'."
  (harness-tools-test-with
    (harness-define-tool "t_chatty" :label "Chatty" :kind 'read
                         :handler (lambda (input ctx)
                                    (funcall (plist-get ctx :report) (plist-get input :text))
                                    (funcall (plist-get ctx :note) (plist-get input :text))
                                    (harness-tool-ok "done")))
    (let ((progress nil) (notes nil) (filtered nil))
      (harness-on 'tools/progress (lambda (sid cid text) (push (list sid cid text) progress)))
      (harness-on 'tools/note (lambda (sid cid text) (push (list sid cid text) notes)))
      (harness-add-filter 'tools/output-text
                          (lambda (text session-id) (push session-id filtered) (upcase text)))
      (harness-tools-test--run "t_chatty" :text "quiet words")
      (should (equal '((nil "c1" "QUIET WORDS")) progress))
      (should (equal '((nil "c1" "QUIET WORDS")) notes))
      (should (equal '(nil nil) filtered))
      ;; A call the user approved by hand reports through the filter too.
      (setq progress nil)
      (harness-await (harness-call 'tools/execute-approved nil
                                   (list :id "c2" :name "t_chatty" :input (list :text "again")))
                     10)
      (should (equal '((nil "c2" "AGAIN")) progress)))))

;;;; A call whose paths cannot be told is not run

(ert-deftest harness-tools-a-call-whose-paths-cannot-be-told-is-refused ()
  "The jail takes a call with no paths for one with nothing to judge.
So a paths function that fails (an argument that is no path) must not
pass for \"no paths\": the call is refused before the permission chain,
even one that would allow everything, and the tool is not run.  A call
whose paths are told runs as it did."
  (harness-tools-test-with
    (let ((ran 0) (chain 0))
      (harness-add-filter 'permission/decide
                          (lambda (_d next &rest _) (cl-incf chain) (funcall next (list :behavior 'allow)))
                          10)
      (harness-define-tool "t_pathful" :label "Pathful" :kind 'read
                           :paths (lambda (input)
                                    ;; The way `file-name-directory' fails on a number.
                                    (list (file-name-directory (plist-get input :path))))
                           :handler (lambda (_input _ctx) (cl-incf ran) "ran"))
      (cl-flet ((call (id &rest input)
                  (harness-test-await (harness-call 'tools/execute nil
                                                    (list :id id :name "t_pathful" :input input)))))
        (should-not (plist-get (call "c1" :path "/work/a.txt") :is-error))
        (should (= 1 ran))
        (should (= 1 chain))
        (let ((r (call "c2" :path 42)))
          (should (plist-get r :is-error))
          (should (plist-get r :denied))
          (should (string-search "could not be worked out" (plist-get r :content)))
          (should (string-search "cannot be checked" (plist-get r :content))))
        (let ((r (call "c3" :path ["a" "b"])))
          (should (plist-get r :is-error))
          (should (plist-get r :denied)))
        ;; Neither reached the tool, nor the chain.
        (should (= 1 ran))
        (should (= 1 chain))))))

;;;; The paths a call touches, for the permission chain

(ert-deftest harness-tools-paths-are-worked-out-without-connecting ()
  "The permission chain decides a call before the user has said it may reach a
host, so the paths of a call are made absolute without asking any: a TRAMP
name in a home directory (/ssh:box:~/src) stays what it says, tidied, where
`expand-file-name' would connect to find the home.  A relative path is
relative to the session's directory, on its host; one that leaves the home
stays as written."
  (harness-tools-test-with
    (harness-define-tool "t_paths" :label "Paths" :kind 'read
                         :paths (lambda (input) (plist-get input :paths))
                         :handler #'ignore)
    (let ((tool (harness-tool-get "t_paths"))
          (host "/ssh:u@box.example.invalid:"))
      (cl-flet ((paths (names &optional ctx)
                  (harness-tools--paths tool (list :paths names) (or ctx (list :cwd "/work/proj/")))))
        (harness-test-without-connections
          ;; A home directory is a place of its own, never expanded.
          (should (equal (list (concat host "~/x") (concat host "~/") (concat host "~/b") (concat host "~/b/")
                               (concat host "/etc"))
                         (paths (list (concat host "~/x") (concat host "~") (concat host "~/a/../b")
                                      (concat host "~/./b//") (concat host "/var/../etc")))))
          ;; The local home directory is not the one of the host.
          (should-not (string-search (expand-file-name "~") (car (paths (list (concat host "~/x"))))))
          ;; Leaving the home: written as it was.
          (should (equal (list (concat host "~/..") (concat host "~/a/../../x"))
                         (paths (list (concat host "~/..") (concat host "~/a/../../x")))))
          ;; Local paths are made absolute against the session's directory.
          (should (equal '("/work/proj/src/a.el" "/work/b" "/etc/hosts" "/work/proj")
                         (paths '("src/a.el" "../b" "/etc/hosts" "."))))
          ;; A session on a host: its paths are on it, a name of another host stays there.
          (let ((ctx (list :cwd "/home/u/proj/" :host host)))
            (should (equal (list (concat host "/home/u/proj/src/a.el") (concat host "/etc/hosts")
                                 (concat host "~/x") "/ssh:other.example.invalid:/etc/hosts")
                           (paths (list "src/a.el" "/etc/hosts" (concat host "~/x")
                                        "/ssh:other.example.invalid:/etc/hosts")
                                  ctx))))
          ;; A session whose directory is a home directory has the relative paths in it.
          (let ((ctx (list :cwd (concat host "~/proj/"))))
            (should (equal (list (concat host "~/proj/src/a.el") (concat host "~/proj/") (concat host "~/x")
                                 "/etc/hosts")
                           (paths '("src/a.el" "." "../x" "/etc/hosts") ctx))))
          ;; A call that touches no path has none.
          (should-not (paths nil)))))))

(ert-deftest harness-tools-resolve-path-is-the-tools-own ()
  "The handlers of the tools resolve a path with `harness-tools-resolve-path',
which expands it as ever once the call is allowed; only the permission
chain's paths avoid that."
  (should (equal "/work/proj/src/a.el" (harness-tools-resolve-path "src/a.el" '(:cwd "/work/proj/"))))
  (should (equal "/work/b" (harness-tools-resolve-path "../b" '(:cwd "/work/proj/"))))
  (should (equal "/etc/hosts" (harness-tools-resolve-path "/etc/hosts" '(:cwd "/work/proj/"))))
  (should (equal (expand-file-name "~/notes") (harness-tools-resolve-path "~/notes" '(:cwd "/work/proj/"))))
  (should (equal "/ssh:box:/srv/app/src/x.el"
                 (harness-tools-resolve-path "src/x.el" '(:cwd "/srv/app/" :host "/ssh:box:"))))
  ;; Where a home directory is named, it is the host that expands it, so the resolver connects.
  (require 'tramp)
  (let (attempts)
    (cl-letf (((symbol-function 'tramp-maybe-open-connection)
               (lambda (vec &rest _)
                 (push (tramp-make-tramp-file-name vec 'noloc) attempts)
                 (error "Nothing may connect"))))
      (ignore-errors (harness-tools-resolve-path "/ssh:u@box.example.invalid:~/x" '(:cwd "/work/proj/"))))
    (should (equal '("/ssh:u@box.example.invalid:") attempts))))

(provide 'harness-tools-test)
;;; harness-tools-test.el ends here
