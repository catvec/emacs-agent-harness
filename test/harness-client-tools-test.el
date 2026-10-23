;;; harness-client-tools-test.el --- The tools the app's tests are tried against  -*- lexical-binding: t; -*-

;;; Commentary:

;; The Flutter app (harness_client/) folds a run of tool calls under one
;; summary line the way the Emacs chat does: exactly the calls of the tools
;; whose spec in `tools/list' says `:coalescable'.  The app keeps no list of
;; its own; it asks the harness, so the two cannot drift apart.
;;
;; Its tests are tried against the real answer, not a list made up there:
;; harness_client/test/support/harness_tools.json holds the tools as the
;; harness serves them.  This suite keeps that file honest.  A tool of the
;; file that is not as the registry has it (renamed, labelled otherwise, moved
;; on or off the allow list, gone) fails here, with how to write the file
;; again.  A tool the registry has and the file has not does not: the file
;; need not hold them all, so adding a tool touches nothing of the app.

;;; Code:

(require 'harness-test-helpers)
(require 'json)

(defvar harness-tools)

(defconst harness-client-tools-test--file
  (expand-file-name "harness_client/test/support/harness_tools.json" harness-test-root)
  "The tools the app's tests are tried against.")

(defun harness-client-tools-test--load ()
  "Load the modules of the harness that define tools, as it has them running."
  (dolist (m '(store project config provider provider-demo tools))
    (harness-test-load-module m))
  ;; Only the tools of the modules, not those other tests made up.
  (clrhash harness-tools)
  (dolist (m '(session agent skills perms tasks merge notifications access redact supervisor))
    (harness-test-load-module m))
  (dolist (file (directory-files (expand-file-name "lisp/modules" harness-test-root)
                                 nil "\\`harness-\\(tools-.*\\)\\.el\\'"))
    (harness-test-load-module (intern (substring file 8 -3)))))

(defun harness-client-tools-test--specs ()
  "Return the tools as `tools/list' says them, by name, as (NAME LABEL KIND FOLDS)."
  (sort (mapcar (lambda (spec)
                  (list (plist-get spec :name)
                        (plist-get spec :label)
                        (format "%s" (plist-get spec :kind))
                        (and (plist-get spec :coalescable) t)))
                (harness-call 'tools/list))
        (lambda (a b) (string< (car a) (car b)))))

(defun harness-client-tools-test--render (specs)
  "Return SPECS, as `harness-client-tools-test--specs' gives them, as the file's text."
  (concat "[\n"
          (mapconcat (lambda (spec)
                       (format "  {\"name\": %s, \"label\": %s, \"kind\": %s, \"coalescable\": %s}"
                               (json-encode-string (nth 0 spec))
                               (json-encode-string (nth 1 spec))
                               (json-encode-string (nth 2 spec))
                               (if (nth 3 spec) "true" "false")))
                     specs ",\n")
          "\n]\n"))

(defun harness-client-tools-test--file-specs ()
  "Return the tools of the app's file, as `harness-client-tools-test--specs' gives them."
  (mapcar (lambda (entry)
            (list (plist-get entry :name)
                  (plist-get entry :label)
                  (plist-get entry :kind)
                  (eq t (plist-get entry :coalescable))))
          (with-temp-buffer
            (insert-file-contents harness-client-tools-test--file)
            (json-parse-buffer :object-type 'plist :array-type 'list
                               :null-object nil :false-object :false))))

(ert-deftest harness-client-tools-the-apps-file-is-what-the-harness-serves ()
  "Each tool of the file the app's tests read is as the registry has it.
It names a tool, says what people call it, its kind and whether its calls
fold, and a run of calls folds in the app when it says so.  When the
registry moved on, write the file again:
  HARNESS_WRITE_CLIENT_TOOLS=1 scripts/test.sh test/harness-client-tools-test.el
then run the app's tests (harness_client/tool/check_build.sh --quick)."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (harness-client-tools-test--load)
    (let ((registry (harness-client-tools-test--specs)))
      (when (getenv "HARNESS_WRITE_CLIENT_TOOLS")
        (with-temp-file harness-client-tools-test--file
          (insert (harness-client-tools-test--render registry))))
      (let ((file (harness-client-tools-test--file-specs))
            (stale nil))
        ;; The file holds tools, and both the ones that fold and the ones
        ;; that do not: a catalogue of one kind would test nothing.
        (should (> (length file) 20))
        (should (cl-some (lambda (tool) (nth 3 tool)) file))
        (should (cl-notevery (lambda (tool) (nth 3 tool)) file))
        (dolist (tool file)
          (let ((now (assoc (car tool) registry)))
            (unless (equal tool now)
              (push (format "%s: the file says %S, the registry says %S (HARNESS_WRITE_CLIENT_TOOLS=1 writes the file again)"
                            (car tool) tool now)
                    stale))))
        (should (equal nil (nreverse stale)))))))

(ert-deftest harness-client-tools-the-allow-list-has-the-calls-the-app-folds ()
  "The tools a person reads about in the app's tests are on the list, or not, as in the chat.
The app's tests name tools whose calls fold (reads, commands) and tools
whose calls must stay in view (writes, questions, a hand-in).  They are
named here too, so that a change of the allow list that breaks what those
tests assume says so on this side."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (harness-client-tools-test--load)
    (let ((registry (harness-client-tools-test--specs)))
      (dolist (name '("read_file" "grep" "bash" "list_dir" "emacs_find_definition"))
        (should (nth 3 (assoc name registry))))
      (dolist (name '("edit_file" "write_file" "ask_user" "spawn_agent" "hand_in" "web_fetch"))
        (should (assoc name registry))
        (should-not (nth 3 (assoc name registry)))))))

(provide 'harness-client-tools-test)
;;; harness-client-tools-test.el ends here
