;;; harness-tramp-test.el --- Tools over a TRAMP working directory  -*- lexical-binding: t; -*-

;;; Commentary:

;; Uses the same local "mock" TRAMP method as Emacs's own test suite,
;; so the remote path code runs for real without any network.

;;; Code:

(require 'harness-test-helpers)
(require 'tramp)

(defun harness-tramp-test--enable-mock ()
  (unless (assoc "mock" tramp-methods)
    (add-to-list 'tramp-methods
                 `("mock"
                   (tramp-login-program        ,tramp-default-remote-shell)
                   (tramp-login-args           (("-i")))
                   (tramp-direct-async         ("-c"))
                   (tramp-remote-shell         ,tramp-default-remote-shell)
                   (tramp-remote-shell-args    ("-c"))
                   (tramp-connection-timeout   10))))
  (setq tramp-verbose 1))

(ert-deftest harness-tramp-tools-run-on-remote-cwd ()
  (harness-tramp-test--enable-mock)
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (dolist (m '(store project config provider provider-demo tools tools-fs tools-shell sandbox perms session))
      (harness-test-load-module m))
    (clrhash harness-sessions)
    (let* ((local (harness-test-temp-dir))
           (remote (concat "/mock::" (directory-file-name local) "/"))
           (s (harness-call 'session/create :cwd remote :permission-mode 'yolo :model "demo:scripted"))
           (id (plist-get s :id)))
      (should (file-remote-p (plist-get s :cwd)))
      (should (plist-get s :host))
      ;; No temporary directory of its own: nothing is made on the host.
      (should-not (harness-call 'session/tmp-dir id))
      (should-not (memq 'tmp (mapcar (lambda (e) (plist-get e :source)) (harness-call 'permission/dirs id))))
      (cl-flet ((run (name input)
                  (harness-await (harness-call 'tools/execute id (list :id name :name name :input input)) 60)))
        (should-not (plist-get (run "write_file" '(:path "hello.txt" :content "line one\nline two\n")) :is-error))
        (should (file-exists-p (expand-file-name "hello.txt" local)))
        (should (string-match-p "line two" (plist-get (run "read_file" '(:path "hello.txt")) :content)))
        (should (string-match-p "hello.txt:2" (plist-get (run "grep" '(:pattern "two" :path ".")) :content)))
        (let ((b (run "bash" '(:command "pwd; ls"))))
          (should-not (plist-get b :is-error))
          (should (string-match-p "hello.txt" (plist-get b :content))))
        ;; The jail applies to remote paths too: it asks for the remote
        ;; directory, and a denial reaches the agent.
        (let* ((p (harness-call 'tools/execute id (list :id "outside" :name "read_file"
                                                        :input '(:path "/etc/hostname"))))
               (pending (progn (harness-test-wait (lambda () (harness-call 'permission/pending id)) 10
                                                  "directory prompt")
                               (car (harness-call 'permission/pending id)))))
          (let ((dir (plist-get (plist-get pending :payload) :dir)))
            (should (file-remote-p dir))
            (should (equal "/etc/" (file-remote-p dir 'localname))))
          (harness-call 'permission/answer id (plist-get pending :id) "deny-once")
          (let ((d (harness-await p 60)))
            (should (plist-get d :is-error))
            (should (string-match-p "denied access" (plist-get d :content)))))))))

(provide 'harness-tramp-test)
;;; harness-tramp-test.el ends here
