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
    (dolist (m '(session agent tools-fs tools-shell tools-ssh tools-emacs tools-web tools-agent skills perms
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
    ;; as tools-dev was when open_harness left Claude Code with no tools.
    (dolist (file (directory-files (expand-file-name "lisp/modules" harness-test-root)
                                   nil "\\`harness-\\(tools-.*\\)\\.el\\'"))
      (harness-test-load-module (intern (substring file 8 -3))))
    (let ((specs (harness-call 'tools/list)))
      (should (member "hand_in" (mapcar (lambda (s) (plist-get s :name)) specs)))
      (should (member "open_harness" (mapcar (lambda (s) (plist-get s :name)) specs)))
      (dolist (spec specs)
        (let ((json (harness-json-encode (plist-get spec :schema))))
          (should-not (string-match-p "\"required\":null" json)))))))

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

(provide 'harness-tools-test)
;;; harness-tools-test.el ends here
