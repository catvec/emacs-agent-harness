;;; -*- lexical-binding: t; -*-
(require 'harness-test-helpers)
(condition-case err
    (harness-test-with-temp-state
      (harness-test-reset-bus)
      (dolist (m '(store project config provider session replay)) (harness-test-load-module m))
      (unless (fboundp 'harness-replay-seam)
        (princ "Frozen transport seam absent; unaffected\n") (kill-emacs 0))
      (let* ((sid (plist-get (harness-call 'session/create :cwd dir :model "fixture:m") :id))
             (request (list :model "fixture:m" :session (list :id sid)))
             (body '(:model "m" :messages [(:role "user" :content "ordinary prompt")]
                     :reasoning (:effort "high")))
             (changed (plist-put (copy-tree body) :reasoning '(:effort "max")))
             (refused 0))
        (harness-replay-seam-keep request "fixture:m" "fixture" body)
        (dotimes (_ 3)
          (condition-case failure
              (when (cdr (harness-replay-seam request "fixture:m" "fixture" changed))
                (cl-incf refused))
            (harness-replay-mutation (cl-incf refused))))
        (princ (format "ordinary subsequent requests refused=%d/3\n" refused))
        (kill-emacs (if (= refused 3) 1 0))))
  (error (princ (format "Cannot exercise revision: %S\n" err)) (kill-emacs 125)))
