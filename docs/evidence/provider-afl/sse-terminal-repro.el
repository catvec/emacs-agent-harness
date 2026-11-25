;;; -*- lexical-binding: t; -*-
(require 'harness-provider-openai)
(let* ((events nil)
       (stream (make-harness-openai--stream
                :on-event (lambda (event) (push event events))))
       failure)
  (condition-case err
      (progn
        (harness-openai--stream-chunk stream "{\"error\":{\"message\":42}}")
        (harness-openai--stream-complete stream))
    (error (setq failure err)))
  (princ (format "failure=%S finished=%S terminal-count=%S events=%S\n"
                 failure (harness-openai--stream-finished stream)
                 (cl-count 'done events :key (lambda (event) (plist-get event :type))) events))
  (kill-emacs (if (= 1 (cl-count 'done events :key (lambda (event) (plist-get event :type)))) 0 1)))
