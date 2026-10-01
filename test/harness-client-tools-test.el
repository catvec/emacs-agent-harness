;;; harness-client-tools-test.el --- Saving options through the UI  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-model)

(ert-deftest harness-client-tools-global-config-is-saved-by-the-ui ()
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (harness-test-load-module 'project)
    (harness-test-load-module 'config)
    (harness-test-connect-ui-client)
    ;; Like a normal session: customize refuses to save under "emacs -q".
    (let* ((init-file-user "")
           (user-init-file (expand-file-name "init.el" harness-state-directory))
           (custom-file (expand-file-name "custom.el" harness-state-directory))
           (harness-model harness-model))
      (harness-call 'config/set 'harness-model "demo:other" :scope 'global)
      (should (equal "demo:other" harness-model))
      (harness-test-wait (lambda () (file-exists-p custom-file)) 5 "custom file")
      (should (string-search "demo:other" (harness-read-file custom-file))))))

(ert-deftest harness-client-tools-customize-save-refuses-foreign-options ()
  (require 'harness-client-tools)
  (should-error (harness-client-tools-customize-save "fill-column" "70"))
  (should-error (harness-client-tools-customize-save nil "70")))

(provide 'harness-client-tools-test)
;;; harness-client-tools-test.el ends here
