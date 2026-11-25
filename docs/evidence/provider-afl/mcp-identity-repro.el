;;; -*- lexical-binding: t; -*-
(require 'harness-util)
(condition-case err
    (let* ((message (harness-json-parse "{\"id\":2,\"id\":1,\"method\":\"ping\"}"))
           (encoded (harness-json-encode message))
           (decoded (harness-json-parse encoded)))
      (princ (format "before-id=%S after-id=%S wire=%s\n"
                     (plist-get message :id) (plist-get decoded :id) encoded))
      (kill-emacs (if (equal message decoded) 0 1)))
  (json-parse-error
   (princ (format "handled refusal: %S\n" err))
   (kill-emacs 0)))
