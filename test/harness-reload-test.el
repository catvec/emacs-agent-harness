;;; harness-reload-test.el --- Tests for plugins and hot reload -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Hot reload is only useful if it is honest: a reloaded plugin must not leave
;; the previous version's tool behind, a broken plugin must not take the rest
;; of the harness with it, and reloading the harness must not disturb live
;; sessions.  These tests check exactly those properties.

;;; Code:

(require 'ert)
(require 'harness)
(require 'harness-mock-provider)
(require 'harness-test-util)

(defmacro harness-reload-test-with-plugins (&rest body)
  "Run BODY with a throwaway plugin directory."
  (declare (indent 0))
  `(harness-test-with-temp-session-dir
     (let ((harness-plugins-directory
            (expand-file-name "plugins" harness-test--directory))
           (harness-plugin-auto-load nil)
           (harness-plugin-watch-harness-directory nil))
       (make-directory harness-plugins-directory t)
       (unwind-protect
           (progn ,@body)
         (when harness-plugin-mode (harness-plugin-mode -1))))))

(defun harness-reload-test--write-plugin (name code)
  "Write plugin NAME with CODE and return its file name."
  (let ((file (expand-file-name (concat name ".el") harness-plugins-directory)))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region code nil file nil 'silent))
    file))

(defconst harness-reload-test--plugin
  "(require 'harness)
(harness-define-tool \"reload-test-tool\"
  :description \"A tool from a plugin\"
  :parameters '(:type \"object\")
  :function (lambda (_args _context)
              (harness-tool-result-create :content \"version one\")))
(provide 'reload-test-plugin)
"
  "A plugin that registers one tool.")

(ert-deftest harness-reload-test-unload-removes-tool ()
  "Unloading a file removes the tools and renderers it registered."
  (harness-reload-test-with-plugins
    (let* ((file (harness-reload-test--write-plugin "reload-test-plugin"
                                                    harness-reload-test--plugin)))
      (load file nil 'nomessage)
      (should (harness-tool-get "reload-test-tool"))
      (should (member "reload-test-tool" (harness-tools-for-file file)))
      (harness-unload-file file)
      (should-not (harness-tool-get "reload-test-tool"))
      (should-not (harness-tools-for-file file)))))

(ert-deftest harness-reload-test-reload-replaces-not-accumulates ()
  "Reloading a plugin replaces its tool with the new definition."
  (harness-reload-test-with-plugins
    (let ((file (harness-reload-test--write-plugin "reload-test-plugin"
                                                   harness-reload-test--plugin)))
      (harness-reload-plugin file)
      (let ((first (harness-tool-get "reload-test-tool")))
        (should first)
        (should (equal (harness-tool-function first)
                       (harness-tool-function first)))
        ;; Change the tool and reload.
        (harness-reload-test--write-plugin
         "reload-test-plugin"
         (replace-regexp-in-string "version one" "version two"
                                   harness-reload-test--plugin))
        (harness-reload-plugin file)
        (let ((second (harness-tool-get "reload-test-tool")))
          (should second)
          (should-not (eq first second))
          ;; Exactly one tool of that name exists, not two.
          (should (= 1 (seq-count (lambda (tool)
                                    (equal (harness-tool-name tool) "reload-test-tool"))
                                  (harness-tool-all)))))))))

(ert-deftest harness-reload-test-broken-plugin-is-isolated ()
  "A plugin that fails to load does not stop the others."
  (harness-reload-test-with-plugins
    (harness-reload-test--write-plugin "aaa-broken" "(this-is-not-a-function)")
    (harness-reload-test--write-plugin "bbb-good"
                                       "(require 'harness)
(harness-define-tool \"bbb-good-tool\"
  :description \"fine\"
  :function (lambda (_args _context)
              (harness-tool-result-create :content \"ok\")))
(provide 'bbb-good)
")
    (let ((loaded (harness-load-plugins)))
      (should (= loaded 1))
      (should (harness-tool-get "bbb-good-tool")))))

(ert-deftest harness-reload-test-plugins-load-in-order ()
  "Plugins are loaded in file name order."
  (harness-reload-test-with-plugins
    (harness-reload-test--write-plugin "b-second" "(provide 'b-second)\n")
    (harness-reload-test--write-plugin "a-first" "(provide 'a-first)\n")
    (let ((order nil))
      (dolist (file (harness-plugin-files))
        (push (file-name-base file) order))
      (should (equal (nreverse order) '("a-first" "b-second"))))))

(ert-deftest harness-reload-test-reload-keeps-sessions ()
  "Reloading the harness keeps live sessions and the tool registry."
  (harness-test-with-temp-session-dir
    (let* ((harness-permission-policy '((:default allow)))
           (harness-providers '((:name mock :kind harness-test :script ((:text "hi")))))
           (harness-models '((:provider mock :id "mock-model")))
           (default-directory (file-name-as-directory harness-test--directory))
           (session (harness-session-create '(:name "kept" :model "mock-model"
                                                     :provider mock)))
           (tools-before (length (harness-tool-all))))
      (harness-provider-setup)
      (let ((message (harness-message-create session 'user "still here")))
        (harness-message-finalize message)
        (harness-session-add-message session message))
      (harness-reload t)
      ;; The session object is the same one, with its transcript intact.
      (should (eq (harness-session-get (harness-session-id session)) session))
      (should (equal (harness-message-content (harness-session-last-message session))
                     "still here"))
      ;; The registry did not grow or shrink.
      (should (= (length (harness-tool-all)) tools-before))
      (harness-session-remove session))))

(ert-deftest harness-reload-test-reload-file ()
  "Reloading a single file picks up its new definition."
  (harness-reload-test-with-plugins
    (let ((file (harness-reload-test--write-plugin "reload-test-plugin"
                                                   harness-reload-test--plugin)))
      (harness-reload-file file)
      (should (harness-tool-get "reload-test-tool"))
      (harness-unload-file file)
      (should-not (harness-tool-get "reload-test-tool")))))

(ert-deftest harness-reload-test-author-plugin-scaffold ()
  "The scaffold compiles and reloads."
  (harness-reload-test-with-plugins
    (let ((file (harness-author-plugin "scaffold-test")))
      (unwind-protect
          (progn
            (should (file-exists-p file))
            (should (harness-reload-plugin file)))
        (kill-buffer (get-file-buffer file))
        (delete-file file)))))

(ert-deftest harness-reload-test-self-extension-tools ()
  "The harness can extend itself through its own tools."
  (harness-reload-test-with-plugins
    (let ((harness-permission-policy '((:default allow)))
          (call (harness-tool-call-create
                 :name "harness_eval"
                 :args-string (harness-json-write (list :code "(+ 1 2)")))))
      (harness-tool-run call nil #'ignore)
      (should (eq (harness-tool-call-status call) 'ok))
      (should (equal (harness-tool-call-result call) "3")))
    (let ((call (harness-tool-call-create
                 :name "harness_define_tool"
                 :args-string (harness-json-write
                               (list :name "self-made"
                                     :description "made at runtime"
                                     :code "(harness-tool-result-create :content \"made it\")")))))
      (harness-tool-run call nil #'ignore)
      (should (eq (harness-tool-call-status call) 'ok))
      (should (harness-tool-get "self-made"))
      (should (member "self-made"
                      (mapcar #'harness-tool-name (harness-tool-all))))
      (harness-unregister-tool "self-made")
      (should-not (harness-tool-get "self-made")))))

(ert-deftest harness-reload-test-plugin-mode-watches ()
  "Enabling the plugin mode watches the plugin directory and disabling stops it."
  (harness-reload-test-with-plugins
    (harness-plugin-mode 1)
    (unwind-protect
        (progn
          (should harness-plugin-mode)
          (should harness--watch-descriptors))
      (harness-plugin-mode -1))
    (should-not harness-plugin-mode)
    (should-not harness--watch-descriptors)))

(ert-deftest harness-reload-test-reload-after-change ()
  "A changed file is reloaded after the debounce delay.
This is the path the file watcher takes, tested without depending on the
platform delivering notifications."
  (harness-reload-test-with-plugins
    (let ((file (harness-reload-test--write-plugin "debounce"
                                                   "(require 'harness)\n(provide 'debounce)\n")))
      (harness--reload-after-change file)
      (should-not (harness-tool-get "debounce-tool"))
      (harness-reload-test--write-plugin
       "debounce"
       "(require 'harness)
(harness-define-tool \"debounce-tool\"
  :description \"debounced\"
  :function (lambda (_args _context)
              (harness-tool-result-create :content \"hi\")))
(provide 'debounce)
")
      (harness--reload-after-change file)
      (should (harness-test-wait-for (lambda () (harness-tool-get "debounce-tool")) 10))
      (harness-unload-file file))))

(ert-deftest harness-reload-test-auto-reload-on-save ()
  "Saving a plugin file reloads it."
  (skip-unless (harness-file-notify-works-p))
  (harness-reload-test-with-plugins
    (let ((file (harness-reload-test--write-plugin "auto-reload"
                                                   "(require 'harness)\n(provide 'auto-reload)\n")))
      (harness-plugin-mode 1)
      (unwind-protect
          (progn
            (harness-reload-test--write-plugin
             "auto-reload"
             "(require 'harness)
(harness-define-tool \"auto-reload-tool\"
  :description \"appeared by itself\"
  :function (lambda (_args _context)
              (harness-tool-result-create :content \"hi\")))
(provide 'auto-reload)
")
            (should (harness-test-wait-for
                     (lambda () (harness-tool-get "auto-reload-tool")) 10)))
        (harness-plugin-mode -1)
        (when (harness-tool-get "auto-reload-tool")
          (harness-unload-file file))))))

(provide 'harness-reload-test)
;;; harness-reload-test.el ends here
