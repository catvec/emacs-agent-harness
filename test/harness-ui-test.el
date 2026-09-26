;;; harness-ui-test.el --- Tests for the UI ACP host -*- lexical-binding: t; -*-

;;; Commentary:

;; The UI host is exercised against the real ACP protocol with fake
;; session/agent services, including the client-side file and permission
;; methods and the event bridging UI features rely on.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-acp)
(require 'harness-acp-inprocess)
(require 'harness-perms)
(require 'harness-tools)
(require 'harness-ui)
(require 'harness-test-helpers)

(harness-module-load 'harness-perms)
(harness-module-load 'harness-ui)

(defvar harness-ui-test--events nil)

(defun harness-ui-test--setup ()
  "Fresh UI state with fake harness services."
  (setq harness-ui-test--events nil)
  (harness-ui-stop)
  (harness-service-register
   "session"
   :module 'harness-ui-test
   :methods '((list . (lambda (&rest _args)
                        (list :sessions (vector (list :sessionId "sess-1"
                                                      :cwd "/tmp"
                                                      :title "Test")))))
              (new . (lambda (&rest _args) (list :sessionId "sess-1")))))
  (harness-ui-start)
  (harness-test-wait-for (lambda () harness-ui--client-connection) 5))

(defmacro harness-ui-test--with-setup (&rest body)
  "Run BODY with the UI connected."
  (declare (indent 0))
  `(unwind-protect (progn (harness-ui-test--setup) ,@body)
     (harness-ui-stop)
     (harness-service-unregister "session")))

(ert-deftest harness-ui-initializes ()
  (harness-ui-test--with-setup
    (should (harness-ui-connected-p))
    (should (harness-test-wait-for (lambda () harness-ui--agent-info) 5))
    (should (equal (plist-get harness-ui--agent-info :name) "emacs-agent-harness"))
    (should (plist-get harness-ui--capabilities :loadSession))))

(ert-deftest harness-ui-requests-the-harness ()
  (harness-ui-test--with-setup
    (let ((deferred (harness-ui-request "session/list" nil)))
      (harness-test-settle deferred 5)
      (should (harness-deferred-resolved-p deferred))
      (should (= (length (plist-get (harness-deferred-value deferred) :sessions)) 1)))))

(ert-deftest harness-ui-bridges-session-updates ()
  (harness-ui-test--with-setup
    (harness-test-wait-for (lambda () harness-ui--agent-info) 5)
    (harness-acp-connection-track-session
     harness-ui--agent-connection "sess-1")
    (harness-on 'harness-ui-update
                (lambda (payload) (push payload harness-ui-test--events)))
    ;; The ACP bridge watches harness events, so emit one.
    (harness-event-define 'session-entry-added :module 'harness-ui-test)
    (harness-emit 'session-entry-added
                  :session-id "sess-1"
                  :entry (list :sessionUpdate "agent_message_chunk"
                               :content (list :type "text" :text "hello")))
    (should (= (length harness-ui-test--events) 1))
    (should (equal (plist-get (car harness-ui-test--events) :session-id) "sess-1"))
    (should (equal (plist-get (plist-get (car harness-ui-test--events) :update) :sessionUpdate)
                   "agent_message_chunk"))))

(ert-deftest harness-ui-serves-file-methods ()
  (harness-ui-test--with-setup
    (harness-test-wait-for (lambda () harness-ui--agent-info) 5)
    (let ((file (make-temp-file "harness-ui-file-" nil ".txt")))
      (unwind-protect
          (progn
            (with-temp-file file (insert "line one\nline two\nline three\n"))
            ;; The agent asks the client (this Emacs) to read a file.
            (let ((deferred (harness-acp-connection-request
                             harness-ui--agent-connection "fs/read_text_file"
                             (list :sessionId "sess-1" :path file :line 2 :limit 1))))
              (harness-test-settle deferred 5)
              (should (equal (plist-get (harness-deferred-value deferred) :content)
                             "line two\n")))
            ;; And to write one.
            (let* ((out (expand-file-name "out.txt" (make-temp-file "harness-ui-dir-" t)))
                   (deferred (harness-acp-connection-request
                              harness-ui--agent-connection "fs/write_text_file"
                              (list :sessionId "sess-1" :path out :content "written"))))
              (harness-test-settle deferred 5)
              (should (equal (with-temp-buffer
                               (insert-file-contents out)
                               (buffer-string))
                             "written"))))
        (ignore-errors (delete-file file))))))

(ert-deftest harness-ui-permission-round-trip ()
  (harness-ui-test--with-setup
    (harness-test-wait-for (lambda () harness-ui--agent-info) 5)
    (let ((answered nil))
      (harness-on 'harness-ui-permission-request
                  (lambda (payload)
                    (setq answered payload)
                    (funcall (plist-get payload :respond) "allow-always")))
      (let* ((deferred (harness-ui--ask-permission
                        (list :session-id "sess-1" :tool-name "bash"
                              :arguments '(:command "ls"))))
             (outcome (progn (harness-test-settle deferred 5)
                             (harness-deferred-value deferred))))
        (should answered)
        (should (equal (plist-get answered :session-id) "sess-1"))
        (should (equal (plist-get (plist-get answered :tool-call) :title) "Run bash"))
        (should (equal (plist-get outcome :outcome) "allow"))
        (should (plist-get outcome :always))))))

(ert-deftest harness-ui-permission-rejection ()
  (harness-ui-test--with-setup
    (harness-test-wait-for (lambda () harness-ui--agent-info) 5)
    (harness-on 'harness-ui-permission-request
                (lambda (payload) (funcall (plist-get payload :respond) "reject-once")))
    (let* ((deferred (harness-ui--ask-permission
                      (list :session-id "sess-1" :tool-name "bash" :arguments nil)))
           (outcome (progn (harness-test-settle deferred 5)
                           (harness-deferred-value deferred))))
      (should (equal (plist-get outcome :outcome) "deny"))
      (should-not (plist-get outcome :always)))))

(ert-deftest harness-ui-installs-the-asker ()
  (harness-ui-test--with-setup
    (should (eq harness-permission-ask-function #'harness-ui--ask-permission))
    (harness-ui-stop)
    (should-not harness-permission-ask-function)))

(ert-deftest harness-ui-refreshes-on-reload ()
  (let ((called nil))
    (harness-ui-test--with-setup
      (add-hook 'harness-ui-refresh-functions (lambda () (setq called t)))
      (harness-emit 'harness-reloaded :module 'harness-ui)
      (should called))))

(ert-deftest harness-ui-connection-tracks-closed-state ()
  (harness-ui-test--with-setup
    (should (harness-ui-connected-p))
    (harness-ui-stop)
    (should-not (harness-ui-connected-p))))

(ert-deftest harness-ui-connects-to-a-remote-acp-server ()
  (require 'harness-acp-tcp)
  (harness-module-load 'harness-acp)
  (harness-module-load 'harness-acp-tcp)
  (harness-module-load 'harness-ui)
  (let* ((server (harness-acp-tcp-server 0 nil "127.0.0.1"))
         (port (process-contact server :service)))
    (unwind-protect
        (progn
          (should port)
          (harness-ui-connect "127.0.0.1" port)
          (should (harness-ui-connected-p))
          ;; The handshake and a real request both travel over TCP.
          (let ((deferred (harness-ui-request "_harness/version" (list))))
            (harness-test-settle deferred 10)
            (should (harness-deferred-resolved-p deferred))
            (should (plist-get (harness-deferred-value deferred) :version)))
          (let ((info (harness-ui-agent-info)))
            (should info)))
      (harness-ui-stop)
      (delete-process server))))

(provide 'harness-ui-test)
;;; harness-ui-test.el ends here
