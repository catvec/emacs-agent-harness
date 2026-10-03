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
    (dolist (m '(session agent tools-fs tools-shell tools-emacs tools-web tools-agent skills perms
                 tasks tools-sessions merge notifications tools-notify))
      (harness-test-load-module m))
    (let ((names (mapcar (lambda (s) (plist-get s :name)) (harness-call 'tools/list))))
      (should (member "read_file" names))
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
    (dolist (m '(session agent tools-fs tools-shell tools-emacs tools-web tools-agent skills perms
                 tasks tools-sessions merge notifications tools-notify tools-handin))
      (harness-test-load-module m))
    (let ((specs (harness-call 'tools/list)))
      (should (member "hand_in" (mapcar (lambda (s) (plist-get s :name)) specs)))
      (dolist (spec specs)
        (let ((json (harness-json-encode (plist-get spec :schema))))
          (should-not (string-match-p "\"required\":null" json)))))))

(provide 'harness-tools-test)
;;; harness-tools-test.el ends here
