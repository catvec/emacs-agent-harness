;;; harness-test.el --- Tests for the bundle entry point -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; The global command prefix and the `?' help screens are bundle-level
;; features: the prefix lives in `harness.el' and every UI mode binds
;; help.  These tests pin the prefix layout and that each screen offers
;; help, without starting the harness or connecting anywhere.

;;; Code:

(require 'ert)
(require 'harness)
(require 'harness-ui-ask)
(require 'harness-ui-chat)
(require 'harness-ui-sessions)
(require 'harness-ui-tree)
(require 'harness-ui-usage)
(require 'harness-ui-worktree)

(ert-deftest harness-global-mode-binds-the-command-prefix ()
  (unwind-protect
      (progn
        (harness-global-mode 1)
        (should (keymapp (key-binding (kbd "C-c h"))))
        (should (eq (key-binding (kbd "C-c h n")) #'harness-ui-chat-new))
        (should (eq (key-binding (kbd "C-c h s")) #'harness-ui-sessions))
        (should (eq (key-binding (kbd "C-c h m")) #'harness-ui-switch-model))
        (should (eq (key-binding (kbd "C-c h r")) #'harness-reload))
        (should (eq (key-binding (kbd "C-c h q")) #'harness-stop)))
    (harness-global-mode -1)))

(ert-deftest harness-help-is-bound-on-every-screen ()
  (dolist (map (list harness-ui-chat-mode-map
                     harness-ui-sessions-mode-map
                     harness-ui-tree-mode-map
                     harness-ui-usage-mode-map
                     harness-ui-worktree-mode-map
                     harness-ui-ask-mode-map))
    (should (commandp (lookup-key map (kbd "?"))))))

(ert-deftest harness-describe-renders-commands-and-the-global-prefix ()
  (unwind-protect
      (progn
        (harness-global-mode 1)
        (with-temp-buffer
          (use-local-map harness-ui-sessions-mode-map)
          (harness-ui-describe))
        (with-current-buffer "*Harness Help*"
          (let ((text (buffer-string)))
            (should (string-match-p "Harness commands" text))
            (should (string-match-p "RET" text))
            (should (string-match-p "Global commands" text))
            (should (string-match-p "C-c h n" text)))))
    (harness-global-mode -1)
    (when (get-buffer "*Harness Help*")
      (kill-buffer "*Harness Help*"))))

(provide 'harness-test)
;;; harness-test.el ends here
