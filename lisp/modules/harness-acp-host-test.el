;;; harness-acp-host-test.el --- Which side of the process split holds the MCP host  -*- lexical-binding: t; -*-

;;; Commentary:

;; An Emacs lends the harness its own Emacs as the MCP server `emacs'
;; (see `harness-acp--attach-emacs').  Only the harness side of the
;; process split may declare and attach one: `harness-mcp' is a module
;; of that side, and the UI of a harness process loads lisp/ui and the
;; ACP client half alone (harness.el, `harness--module-files').  These
;; tests hold the boundary there: the UI side declares nothing and
;; attaches nothing, whatever host symbols or features happen to be
;; defined in it, and the harness side and the Emacs a harness runs in
;; declare and attach as they always did.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-acp--emacs-mcp)
(defvar harness-acp--server-enabled)
(defvar harness-acp-token)

(declare-function harness-mcp-server-declared-p "harness-mcp" (name))
(declare-function harness-emacs-endpoint-client-capabilities "harness-emacs-endpoint" ())

(defvar harness-acp-host-test--declared nil
  "The servers a stubbed host was asked to declare, newest first.")

(defvar harness-acp-host-test--saved nil
  "The host's own `harness-mcp-define-server', or nil when it had none.")

(defun harness-acp-host-test--stub-host ()
  "Make `harness-mcp-define-server' a stub recording into the declared list.
A UI that some code loaded the host into must still declare nothing, so
what the stub records is what tells a declaration from a load."
  (setq harness-acp-host-test--declared nil
        harness-acp-host-test--saved (and (fboundp 'harness-mcp-define-server)
                                          (symbol-function 'harness-mcp-define-server)))
  (fset 'harness-mcp-define-server
        (lambda (name &rest _)
          (push name harness-acp-host-test--declared)
          name)))

(defun harness-acp-host-test--unstub-host ()
  "Put the host's own declaration function back, or take the stub away."
  (if harness-acp-host-test--saved
      (fset 'harness-mcp-define-server harness-acp-host-test--saved)
    (when (fboundp 'harness-mcp-define-server)
      (fmakunbound 'harness-mcp-define-server)))
  (setq harness-acp-host-test--saved nil))

(defmacro harness-acp-host-test--with-stub (&rest body)
  "Run BODY with the host's declarations recorded, and the host put back after."
  (declare (indent 0))
  `(progn
     (harness-acp-host-test--stub-host)
     (unwind-protect (progn ,@body)
       (harness-acp-host-test--unstub-host))))

(defun harness-acp-host-test--lend (client-capabilities)
  "Initialise a local client that lends what CLIENT-CAPABILITIES says."
  (let ((conn (harness-acp-connect nil)))
    (harness-acp-set-handler
     conn (lambda (_method _params respond)
            (when respond
              (harness-acp-respond-error respond -32601 "unhandled"))))
    (unwind-protect
        (harness-test-await (harness-acp-initialize conn client-capabilities))
      (harness-acp-close conn))))

;;;; The UI of a harness process holds no host

(ert-deftest harness-acp-host-the-ui-of-a-split-declares-no-mcp-server ()
  "The UI side of the split declares nothing, though the host's symbols are here.
`harness-process' is non-nil in the UI of a harness process, which loads
lisp/ui and the ACP client half alone; the host's symbols being defined
in it does not make it the host."
  (let ((harness-process t)
        (harness-module-directories '("lisp/ui")))
    (harness-acp-host-test--with-stub
      (should-not (harness-acp--emacs-server))
      (should-not harness-acp-host-test--declared))))

(ert-deftest harness-acp-host-the-ui-of-a-split-loads-no-mcp-module ()
  "Nothing on the UI side loads `harness-mcp', nor registers it as a module.
Requiring it there would register it, and its requirements (config among
them), in the UI's registry, where they cannot start: the live line is
`mcp failed: requirements not ready: (config)'.  The host's symbols are
taken out first, so the test says the same thing whatever ran before it:
the load it forbids is the one a UI does when it holds no host yet."
  (let ((harness-process t)
        (harness-module-directories '("lisp/ui"))
        (required nil)
        (orig-require (symbol-function 'require))
        (saved (mapcar (lambda (sym)
                         (cons sym (and (fboundp sym) (symbol-function sym))))
                       '(harness-mcp-attach harness-mcp-define-server))))
    (unwind-protect
        (progn
          (dolist (sym '(harness-mcp-attach harness-mcp-define-server))
            (when (fboundp sym) (fmakunbound sym)))
          (cl-letf (((symbol-function 'require)
                     (lambda (feature &optional filename noerror)
                       (when (eq feature 'harness-mcp)
                         (push feature required))
                       (if (eq feature 'harness-mcp)
                           nil
                         (funcall orig-require feature filename noerror)))))
            (should-not (harness-acp--emacs-server)))
          (should-not required))
      (dolist (cell saved)
        (when (cdr cell) (fset (car cell) (cdr cell)))))))

(ert-deftest harness-acp-host-a-ui-some-code-contaminated-declares-nothing ()
  "A UI with the host's feature and symbols present still declares nothing.
This is the case the predicate must not be fooled by: `featurep' alone,
or the host's symbols being defined, would take the UI for the host."
  (let ((harness-process t)
        (harness-module-directories '("lisp/ui")))
    (harness-acp-host-test--with-stub
      ;; The contamination: the host's feature, its symbols with it.
      (provide 'harness-mcp)
      (unwind-protect
          (progn
            (should (featurep 'harness-mcp))
            (should (fboundp 'harness-mcp-define-server))
            (should-not (harness-acp--emacs-server))
            (should-not harness-acp-host-test--declared))
        (setq features (delq 'harness-mcp features))))))

(ert-deftest harness-acp-host-a-ui-some-code-contaminated-attaches-nothing ()
  "A client that lends an Emacs to a contaminated UI gets no MCP connection.
The UI of a harness process runs ACP, and its own client lends this
Emacs, so `harness-acp--init' and `initialize' reach the attach path
there.  With no host on that side, no connection is made."
  (let ((harness-process t)
        (harness-module-directories '("lisp/ui"))
        (harness-acp-token nil)
        (harness-acp--server-enabled nil)
        (harness-acp--emacs-mcp (make-hash-table :test 'eq)))
    (harness-acp-host-test--with-stub
      (provide 'harness-mcp)
      (unwind-protect
          (progn
            (harness-acp-host-test--lend
             (harness-emacs-endpoint-client-capabilities))
            (should (zerop (hash-table-count harness-acp--emacs-mcp)))
            (should-not harness-acp-host-test--declared))
        (setq features (delq 'harness-mcp features))))))

;;;; The harness side, and the Emacs a harness runs in, declare and attach

(ert-deftest harness-acp-host-the-harness-side-of-a-split-declares-the-server ()
  "The harness side of the split is the host, and declares the server.
It is the harness process, which loads lisp/modules and sets
`harness-process' nil for itself (harness-server.el)."
  (let ((harness-process nil)
        (harness-module-directories '("lisp/modules")))
    (harness-acp-host-test--with-stub
      (should (harness-acp--emacs-server))
      (should (equal '(emacs) harness-acp-host-test--declared)))))

(ert-deftest harness-acp-host-the-emacs-a-harness-runs-in-declares-the-server ()
  "Colocated mode is the host too: the harness, and its UI, are in this Emacs.
That is `harness-process' nil with both module directories loaded."
  (let ((harness-process nil)
        (harness-module-directories '("lisp/modules" "lisp/ui")))
    (harness-acp-host-test--with-stub
      (should (harness-acp--emacs-server))
      (should (equal '(emacs) harness-acp-host-test--declared)))))

(ert-deftest harness-acp-host-the-harness-side-attaches-the-lent-emacs ()
  "Where the host is here, a client that lends an Emacs is attached.
The host records the connection it made under the client, not the ACP
connection: `harness-acp--attach-emacs' puts it in
`harness-acp--emacs-mcp' with the client as the key.  The hook is
let-bound, not added and removed, so a hook the harness already had is
left as it was."
  (let ((harness-process nil)
        (harness-module-directories '("lisp/modules"))
        (harness-acp-token nil)
        (harness-acp--server-enabled nil)
        (harness-acp--emacs-mcp (make-hash-table :test 'eq))
        (harness-acp-initialized-functions
         (cons #'harness-acp--attach-emacs harness-acp-initialized-functions))
        (asked nil))
    (let* ((conn (harness-acp-connect nil))
           (client (harness-acp-connection-client conn)))
      (harness-acp-set-handler
       conn (lambda (method params respond)
              (push method asked)
              (unless (and (equal method harness-emacs-endpoint-mcp-method)
                           (harness-emacs-endpoint-answer method params respond))
                (when respond
                  (harness-acp-respond-error respond -32601 "unhandled")))))
      (unwind-protect
          (progn
            (harness-test-await
             (harness-acp-initialize conn (harness-emacs-endpoint-client-capabilities)))
            ;; The handshake is a round trip: the connection is recorded once
            ;; the client has answered `initialize', so wait for it.
            (harness-test-wait (lambda () (gethash client harness-acp--emacs-mcp)) 5
                               "the host to attach the lent Emacs")
            (should (gethash client harness-acp--emacs-mcp))
            (should (member harness-emacs-endpoint-mcp-method asked)))
        (harness-acp-close conn)))))

(provide 'harness-acp-host-test)
;;; harness-acp-host-test.el ends here
