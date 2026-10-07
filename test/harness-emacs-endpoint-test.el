;;; harness-emacs-endpoint-test.el --- Tools run in the harness; an Emacs is lent to it  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every tool runs in the harness.  The tools about the user's Emacs
;; reach the Emacs a client lent to the harness (advertised in
;; `initialize'), exactly one of them, and never a client that lends
;; none, such as a phone.  These tests connect in-process clients of
;; both kinds and check who is asked, what they answer, and what the
;; tools make of it.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-model)
(defvar harness-tools-max-output-chars)
(declare-function harness-acp-add-client "harness-acp")
(declare-function harness-acp-client-receive "harness-acp")
(declare-function harness-acp-drop-client "harness-acp")
(declare-function harness-acp-close "harness-acp")
(declare-function harness-acp-request "harness-acp")
(declare-function harness-acp-respond-error "harness-acp")
(declare-function harness-emacs-endpoint-handle "harness-emacs-endpoint")

(defvar harness-emacs-endpoint-test--evaluations 0
  "How many times test code evaluated in this Emacs.")

(defun harness-emacs-endpoint-test--allow (_decision next &rest _)
  "Permissive permission filter for the tests."
  (funcall next (list :behavior 'allow)))

(defun harness-emacs-endpoint-test--setup ()
  "Load the tool modules and acp, allow every call, and drop every client.
Each test then connects the clients it is about, and only those."
  (setq harness-acp--server-enabled nil)
  (harness-test-load-module 'acp)
  (harness-test-load-module 'tools)
  (harness-test-load-module 'tools-emacs)
  (harness-test-load-module 'tools-shell)
  (require 'harness-emacs-endpoint)
  (harness-add-filter 'permission/decide #'harness-emacs-endpoint-test--allow 10)
  (dolist (client (copy-sequence harness-acp--clients))
    (harness-acp-drop-client client)))

(defun harness-emacs-endpoint-test--connect (lend)
  "Connect an in-process client; it lends this Emacs when LEND.
Return (CONNECTION . SEEN): SEEN is a cons whose car lists the methods
the harness sent the client, newest first.  A client that lends no
Emacs (a phone, say) answers no request; one that does answers the
harness's requests for its Emacs."
  (let ((conn (harness-acp-connect nil))
        (seen (list nil)))
    (harness-acp-set-handler
     conn
     (lambda (method params respond)
       (push method (car seen))
       (unless (and lend (harness-emacs-endpoint-answer method params respond))
         (when respond (harness-acp-respond-error respond -32601 (format "unhandled %s" method))))))
    (harness-test-await (harness-acp-initialize conn (and lend (harness-emacs-endpoint-client-capabilities))))
    (cons conn seen)))

(defun harness-emacs-endpoint-test--call (name &rest input)
  "Execute tool NAME with INPUT through tools/execute and wait."
  (harness-test-await (harness-call 'tools/execute nil (list :id "c1" :name name :input input)) 20))

(defun harness-emacs-endpoint-test--asked-p (seen)
  "Non-nil when SEEN, from `harness-emacs-endpoint-test--connect', got a tool's request."
  (cl-some (lambda (method) (or (string-prefix-p "_harness/emacs/" method)
                                (equal method "_harness/client/tool")))
           (car seen)))

;;;; Who is asked

(ert-deftest harness-emacs-endpoint-a-client-that-lends-no-emacs-is-never-asked ()
  "With only a phone-like client, the harness has no Emacs to ask: the
tools about the user's Emacs say so at once, the elisp tool evaluates
in the background as always, and the client gets no tool request."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let ((phone (harness-emacs-endpoint-test--connect nil)))
      (unwind-protect
          (progn
            (should-not (harness-call 'emacs/attached))
            (dolist (call '(("emacs_buffers") ("emacs_buffer" :name "*scratch*")
                            ("emacs_describe" :symbol "car") ("emacs_messages")))
              (let ((r (apply #'harness-emacs-endpoint-test--call call)))
                (should (plist-get r :is-error))
                (should (string-prefix-p "No Emacs is attached to the harness" (plist-get r :content)))
                (should (string-search "elisp tool" (plist-get r :content)))))
            ;; The debugging tools point elsewhere: a definition can be
            ;; grepped for; a trace has nothing to stand in for it.
            (dolist (call '(("emacs_find_definition" :symbol "car" "grep")
                            ("emacs_trace" :symbol "car" nil)))
              (let ((r (harness-emacs-endpoint-test--call (nth 0 call) (nth 1 call) (nth 2 call))))
                (should (plist-get r :is-error))
                (should (string-prefix-p "No Emacs is attached to the harness" (plist-get r :content)))
                (if (nth 3 call)
                    (should (string-search (nth 3 call) (plist-get r :content)))
                  (should-not (string-search "elisp tool" (plist-get r :content))))))
            (let ((r (harness-emacs-endpoint-test--call "elisp" :code "(+ 1 2)")))
              (should (equal "=> 3" (plist-get r :content)))
              (should (equal "background" (plist-get (plist-get r :meta) :emacs))))
            ;; No Emacs to ask, and no request that evaluates in one
            ;; even if there were: a call that asks is refused for that
            ;; reason first.
            (let ((r (harness-emacs-endpoint-test--call "elisp" :code "(+ 1 2)" :emacs "user")))
              (should (plist-get r :is-error))
              (should (string-search "never evaluates in the user's Emacs" (plist-get r :content)))
              (should (string-search "emacs_* tools" (plist-get r :content))))
            (should-not (harness-emacs-endpoint-test--asked-p (cdr phone))))
        (harness-acp-close (car phone))))))

(ert-deftest harness-emacs-endpoint-the-lending-emacs-answers-beside-a-phone ()
  "A phone and an Emacs connected at once: the Emacs is asked, the phone never."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let* ((emacs (harness-emacs-endpoint-test--connect t))
           (phone (harness-emacs-endpoint-test--connect nil))
           (buffer (generate-new-buffer "harness-endpoint-lent")))
      (unwind-protect
          (progn
            ;; The phone spoke last, yet it lends no Emacs.
            (harness-test-await (harness-acp-request (car phone) "_harness/harness/version" nil))
            (let ((attached (harness-call 'emacs/attached)))
              (should (= 1 (length attached)))
              (should (equal (emacs-pid) (plist-get (car attached) :pid)))
              (should (equal emacs-version (plist-get (car attached) :version))))
            (should (string-search "harness-endpoint-lent"
                                   (plist-get (harness-emacs-endpoint-test--call "emacs_buffers") :content)))
            (should (member "_harness/emacs/buffers" (car (cdr emacs))))
            (should-not (harness-emacs-endpoint-test--asked-p (cdr phone))))
        (kill-buffer buffer)
        (harness-acp-close (car phone))
        (harness-acp-close (car emacs))))))

(ert-deftest harness-emacs-endpoint-exactly-one-emacs-answers ()
  "Two Emacsen lent at once: a request goes to one of them, the most
recently active, never to both.  A broadcast would, for instance, open
the same file in every connected Emacs."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let ((a (harness-emacs-endpoint-test--connect t))
          (b (harness-emacs-endpoint-test--connect t)))
      (unwind-protect
          (progn
            ;; A is where the user is now.
            (harness-test-await (harness-acp-request (car a) "_harness/harness/version" nil))
            (let ((r (harness-emacs-endpoint-test--call "emacs_windows")))
              (should-not (plist-get r :is-error))
              (should (string-search "FRAME" (plist-get r :content))))
            (should (member "_harness/emacs/windows" (car (cdr a))))
            (should-not (member "_harness/emacs/windows" (car (cdr b))))
            ;; Then B: the request follows the user, still to one Emacs.
            (harness-test-await (harness-acp-request (car b) "_harness/harness/version" nil))
            (harness-emacs-endpoint-test--call "emacs_windows")
            (should (member "_harness/emacs/windows" (car (cdr b))))
            (should (= 1 (cl-count "_harness/emacs/windows" (car (cdr a)) :test #'equal))))
        (harness-acp-close (car a))
        (harness-acp-close (car b))))))

(ert-deftest harness-emacs-endpoint-an-unauthenticated-client-lends-nothing ()
  "A client that has not authenticated may advertise an Emacs, but is
not one the harness asks: it could answer for the user's Emacs, and be
shown its buffers, with what it likes."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let* ((sent nil)
           (client (harness-acp-add-client 'test :writer (lambda (_client text) (push text sent))
                                           :remote '(:address "192.0.2.7"))))
      (unwind-protect
          (progn
            (harness-acp-client-receive
             client (harness-json-encode-text
                     (list :jsonrpc "2.0" :id 1 :method "initialize"
                           :params (list :protocolVersion 1
                                         :clientCapabilities (harness-emacs-endpoint-client-capabilities)))))
            (harness-test-wait (lambda () sent) 5 "initialize answer")
            (should-not (harness-call 'emacs/attached))
            (let ((r (harness-emacs-endpoint-test--call "emacs_buffers")))
              (should (string-prefix-p "No Emacs is attached" (plist-get r :content))))
            (should-not (cl-some (lambda (text) (string-search "_harness/emacs/" text)) sent)))
        (harness-acp-drop-client client)))))

(ert-deftest harness-emacs-endpoint-an-emacs-that-leaves-fails-the-call ()
  "An Emacs that disconnects before it answers fails the call, saying so."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let ((conn (harness-acp-connect nil)))
      (harness-test-await (harness-acp-initialize conn (harness-emacs-endpoint-client-capabilities)))
      (harness-acp-set-handler conn (lambda (method &rest _)
                                      (when (string-prefix-p "_harness/emacs/" method)
                                        (run-at-time 0 nil #'harness-acp-close conn))))
      (let ((r (harness-emacs-endpoint-test--call "emacs_buffers")))
        (should (plist-get r :is-error))
        (should (string-prefix-p "The user's Emacs disconnected before it answered." (plist-get r :content)))))))

(defvar harness-ui-connection)
(declare-function harness-ui--advertise "harness-ui")
(declare-function harness-ui--dispatch "harness-ui")

(ert-deftest harness-emacs-endpoint-the-ui-lends-its-emacs-again-after-a-reload ()
  "A connection the UI opened with older code lent nothing; after a
reload the UI advertises its Emacs on it, and its dispatch answers for
that Emacs."
  (harness-emacs-endpoint-test--setup)
  (require 'harness-ui)
  (harness-test-with-temp-state
    (let ((conn (harness-acp-connect nil))
          (buffer (generate-new-buffer "harness-endpoint-reloaded")))
      (unwind-protect
          (progn
            (harness-acp-set-handler conn #'harness-ui--dispatch)
            ;; Older code: ACP's own capabilities only.
            (harness-test-await (harness-acp-initialize conn))
            (should-not (harness-call 'emacs/attached))
            (let ((harness-ui-connection conn))
              (harness-ui--advertise)
              (harness-test-wait (lambda () (harness-call 'emacs/attached)) 5 "the UI's Emacs to be lent"))
            (should (equal (emacs-pid) (plist-get (car (harness-call 'emacs/attached)) :pid)))
            (should (string-search "harness-endpoint-reloaded"
                                   (plist-get (harness-emacs-endpoint-test--call "emacs_buffers") :content))))
        (kill-buffer buffer)
        (harness-acp-close conn)))))

;;;; What the Emacs answers

(ert-deftest harness-emacs-endpoint-answers-data-not-tool-results ()
  "The lent Emacs sends plain data; the tools word it in the harness."
  (require 'harness-emacs-endpoint)
  (let ((buffer (generate-new-buffer "harness-endpoint-data")))
    (unwind-protect
        (progn
          (with-current-buffer buffer (insert "alpha\nbeta\n") (set-buffer-modified-p nil))
          (let ((row (cl-find "harness-endpoint-data" (plist-get (harness-emacs-endpoint-handle "buffers" nil) :buffers)
                              :key (lambda (b) (plist-get b :name)) :test #'equal)))
            (should (equal "fundamental-mode" (plist-get row :mode)))
            (should (eq :false (plist-get row :modified)))
            (should (= 11 (plist-get row :size))))
          (should (equal '(:exists :false) (harness-emacs-endpoint-handle "buffer" '(:name "harness-endpoint-none"))))
          (let ((answer (harness-emacs-endpoint-handle "buffer" '(:name "harness-endpoint-data" :offset 2))))
            (should (equal '("beta") (plist-get answer :lines)))
            (should (= 2 (plist-get answer :first)))
            (should (= 2 (plist-get answer :total))))
          (let ((answer (harness-emacs-endpoint-handle "describe" '(:symbol "car"))))
            (should (eq t (plist-get answer :known)))
            (should (equal "primitive" (plist-get (plist-get answer :function) :kind)))
            (should (string-prefix-p "(car " (plist-get (plist-get answer :function) :signature)))
            (should-not (plist-get answer :variable)))
          (should (eq :false (plist-get (harness-emacs-endpoint-handle "describe" '(:symbol "harness-endpoint-nonesuch-q"))
                                        :known)))
          (let ((answer (harness-emacs-endpoint-handle "definition" '(:symbol "car"))))
            (should (eq t (plist-get answer :known)))
            (should (equal "function" (plist-get answer :type)))
            (should (equal "built-in function" (plist-get answer :kind)))
            (should (eq :false (plist-get answer :advised))))
          (should (eq :false (plist-get (harness-emacs-endpoint-handle "definition" '(:symbol "harness-endpoint-nonesuch-q"))
                                        :known)))
          (let ((answer (harness-emacs-endpoint-handle "trace" '(:action "list"))))
            (should (equal "*trace-output*" (plist-get answer :buffer)))
            (should (integerp (plist-get answer :lines))))
          (should-error (harness-emacs-endpoint-handle "trace" '(:action "eval" :symbol "car")))
          (should-error (harness-emacs-endpoint-handle "shell" nil))
          ;; No request evaluates code: the vocabulary a lent Emacs
          ;; answers has no eval, whatever is configured.
          (should-not (assoc "eval" harness-emacs-endpoint--methods))
          (should-error (harness-emacs-endpoint-handle "eval" '(:code "(+ 1 2)"))))
      (kill-buffer buffer))))

(ert-deftest harness-emacs-endpoint-reads-are-bounded ()
  "Nothing big crosses from the user's Emacs: a long buffer is read in
ranges, a long line is cut, and a big value is printed only in part."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let ((conn (harness-test-connect-ui-client))
          (buffer (generate-new-buffer "harness-endpoint-long"))
          (harness-tools-max-output-chars 1500))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (dotimes (i 300) (insert (format "line %03d of the long buffer\n" (1+ i)))))
            (let* ((c (plist-get (harness-emacs-endpoint-test--call "emacs_buffer" :name "harness-endpoint-long") :content))
                   (next (and (string-match "read on with offset \\([0-9]+\\)" c)
                              (string-to-number (match-string 1 c)))))
              (should next)
              (should (< 1 next 300))
              (should (string-search "lines 1-" c))
              (should (< (length c) harness-tools-max-output-chars))
              (let ((c2 (plist-get (harness-emacs-endpoint-test--call "emacs_buffer" :name "harness-endpoint-long"
                                                                      :offset next)
                                   :content)))
                (should (string-prefix-p (format "%6d\tline %03d" next next) c2))))
            ;; One line longer than a whole read is cut, and the read goes on after it.
            (with-current-buffer buffer (erase-buffer) (insert (make-string 5000 ?x) "\nshort\n"))
            (let ((c (plist-get (harness-emacs-endpoint-test--call "emacs_buffer" :name "harness-endpoint-long") :content)))
              (should (string-search "read on with offset 2" c))
              (should (< (length c) harness-tools-max-output-chars)))
            ;; A long list is printed in part by the user's Emacs.
            (defvar harness-emacs-endpoint-test--long (number-sequence 1 100000))
            (let ((c (plist-get (harness-emacs-endpoint-test--call "emacs_describe" :symbol "harness-emacs-endpoint-test--long")
                                :content)))
              (should (string-search "value: (1 2 3" c))
              (should (< (length c) 800))))
        (kill-buffer buffer)
        (harness-acp-close conn)))))

;;;; Chores of the UI

(ert-deftest harness-emacs-endpoint-global-config-is-saved-by-the-ui ()
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

(ert-deftest harness-emacs-endpoint-customize-save-refuses-foreign-options ()
  (require 'harness-emacs-endpoint)
  (should-error (harness-emacs-endpoint-customize-save "fill-column" "70"))
  (should-error (harness-emacs-endpoint-customize-save nil "70")))

(provide 'harness-emacs-endpoint-test)
;;; harness-emacs-endpoint-test.el ends here
