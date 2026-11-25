;;; -*- lexical-binding: t; -*-
(require 'harness-perms)
(let ((result (harness-perms--read-verdict
               "{\"decision\":\"allow\"}\n{\"decision\":\"allow\",\"decision\":\"deny\"}")))
  (princ (format "%S\n" result))
  (kill-emacs (if (plist-get result :behavior) 1 0)))
