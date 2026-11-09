;;; harness-computer-endpoint-test.el --- Tests for the client side of a computer  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness.

;;; Commentary:

;; The computer endpoint (harness-computer-endpoint.el): what this
;; client says about the computer it runs on, the MCP server it answers
;; for it, and the registration and attachment it makes with a harness
;; elsewhere.  The programs of the computer are stubbed: no screen is
;; captured and no clipboard is read, only what the client would do.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-acp)
(require 'harness-computer-endpoint)

(defvar harness-computer-endpoint--attached)
(defvar harness-computer-endpoint--id)
(defvar harness-computer-endpoint--token)
(declare-function harness-computer-endpoint-answer "harness-computer-endpoint" (method params respond))
(declare-function harness-computer-endpoint-capabilities "harness-computer-endpoint" ())
(declare-function harness-computer-endpoint-client-capabilities "harness-computer-endpoint" (&optional base))
(declare-function harness-computer-endpoint-info "harness-computer-endpoint" ())
(declare-function harness-computer-endpoint-id "harness-computer-endpoint" ())
(declare-function harness-computer-endpoint-name "harness-computer-endpoint" ())
(declare-function harness-computer-endpoint-register "harness-computer-endpoint" (request &optional callback on-error))
(declare-function harness-computer-endpoint-attach "harness-computer-endpoint" (request computer &optional callback on-error))
(declare-function harness-computer-endpoint-refresh "harness-computer-endpoint" (request &optional computer callback on-error))
(declare-function harness-computer-endpoint-unregister "harness-computer-endpoint" (request computer &optional callback on-error))
(declare-function harness-computer-endpoint--resources "harness-computer-endpoint" ())
(declare-function harness-mcp-result-text "harness-mcp-protocol" (result))

(defun harness-computer-endpoint-test-id-file (dir)
  "Return a path for this computer's id in DIR."
  (expand-file-name "computer-id" dir))

(defun harness-computer-endpoint-test-secret-file (dir)
  "Return a path for this computer's secret in DIR."
  (expand-file-name "computer-secret" dir))

(defmacro harness-computer-endpoint-test-with (&rest body)
  "Run BODY with the endpoint's files in a fresh state directory."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (let* ((dir (file-name-as-directory (make-temp-file "harness-endpoint-" t)))
            (harness-computer-endpoint-id-file (harness-computer-endpoint-test-id-file dir))
            (harness-computer-endpoint-secret-file (harness-computer-endpoint-test-secret-file dir))
            (harness-computer-endpoint-resource-roots nil)
            (harness-computer-endpoint-resources nil)
            (harness-computer-endpoint-vnc-url nil)
            (harness-computer-endpoint-name nil)
            (harness-computer-endpoint--attached nil)
            (harness-computer-endpoint--id nil))
       (clrhash harness-computer-endpoint--token)
       (unwind-protect (progn ,@body)
         (ignore-errors (delete-directory dir t))))))

(defun harness-computer-endpoint-test-programs (&rest names)
  "Return a function of a program naming the first of NAMES it knows.
It is what `executable-find' is stubbed with."
  (lambda (program &rest _)
    (and (member program names) (expand-file-name program "/usr/bin"))))

(defmacro harness-computer-endpoint-test-when (session programs &rest body)
  "Run BODY with SESSION (`wayland' or `x11') and PROGRAMS in this computer.
The display is graphic, and the programs are the ones PROGRAMS names."
  `(cl-letf (((symbol-function 'harness-computer-endpoint--session-type)
              (lambda () ,session))
             ((symbol-function 'display-graphic-p)
              (lambda (&optional _frame) t))
             ((symbol-function 'executable-find)
              (apply #'harness-computer-endpoint-test-programs ,programs)))
     ,@body))

(defun harness-computer-endpoint-test-respond (method params &optional computer server token)
  "Send METHOD with PARAMS as the harness would, and return (ANSWERED . VALUE).
COMPUTER, SERVER and TOKEN are `_harness/computer/mcp' params; the
answer is the response or the error the client gives."
  (let ((answered nil)
        (value nil))
    (let ((handled
           (harness-computer-endpoint-answer
            method
            (append (list :computer (or computer (harness-computer-endpoint-id))
                          :server (or server "computer")
                          :token token)
                    params)
            (lambda (answer) (setq answered t value answer)))))
      (unless handled
        (error "The endpoint did not handle %s" method))
      (cons answered value))))

(defun harness-computer-endpoint-test-mcp (method &optional params)
  "Return one MCP message calling METHOD with PARAMS."
  (list :jsonrpc "2.0" :id 7 :method method :params (or params (list :empty t))))

;;;; What this computer is

(ert-deftest harness-computer-endpoint-capabilities-follow-the-programs ()
  "A Wayland computer offers what its tools can do, and no more."
  (harness-computer-endpoint-test-with
    (harness-computer-endpoint-test-when
        'wayland '("grim" "swaymsg" "ydotool" "pw-record")
      (should (equal '("view" "windows" "pointer" "keyboard" "clipboard" "audio")
                     (harness-computer-endpoint-capabilities)))))
  (harness-computer-endpoint-test-with
    (harness-computer-endpoint-test-when
        'x11 '("scrot" "wmctrl" "xdotool")
      (should (equal '("view" "windows" "pointer" "keyboard" "clipboard")
                     (harness-computer-endpoint-capabilities)))))
  (harness-computer-endpoint-test-with
    (harness-computer-endpoint-test-when
        'x11 '()
      ;; This Emacs can still lend its own frame as a picture.
      (should (equal '("view" "clipboard")
                     (harness-computer-endpoint-capabilities))))))

(ert-deftest harness-computer-endpoint-lends-another-display ()
  "A client that lends an X display offers a sandbox there, and no clipboard.
The programs act on that display, not on the one this Emacs draws in."
  (harness-computer-endpoint-test-with
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) t))
              ((symbol-function 'executable-find)
               (harness-computer-endpoint-test-programs "scrot" "wmctrl" "xdotool")))
      (let ((harness-computer-endpoint-display ":99")
            (harness-computer-endpoint-vnc-url "http://127.0.0.1:6080/vnc_lite.html")
            (harness-computer-endpoint-vnc-socket "ws://127.0.0.1:6080/websockify"))
        (should (equal '("view" "windows" "pointer" "keyboard" "sandbox")
                       (harness-computer-endpoint-capabilities)))
        (should-not (harness-computer-endpoint-window-scoped-p))
        (let ((environment (harness-computer-endpoint--process-environment)))
          (should (member "DISPLAY=:99" environment))
          (should (member "XDG_SESSION_TYPE=x11" environment))
          (should-not (cl-some (lambda (entry)
                                 (string-prefix-p "WAYLAND_DISPLAY=" entry))
                               environment)))
        (let ((info (harness-computer-endpoint-info)))
          (should (equal ":99" (plist-get info :display)))
          (should (equal "ws://127.0.0.1:6080/websockify"
                         (plist-get info :vnc-socket)))
          (should (equal "http://127.0.0.1:6080/vnc_lite.html"
                         (plist-get info :vnc))))))))

(ert-deftest harness-computer-endpoint-a-wayland-pointer-is-the-compositors ()
  "A headless Wayland compositor's pointer is sway's, and its keys are wtype's.
No program of the client can drive them; the compositor's IPC and wtype
are what the computer offers."
  (harness-computer-endpoint-test-with
    (harness-computer-endpoint-test-when
        'wayland '("grim" "swaymsg" "wtype")
      (should (member "pointer" (harness-computer-endpoint-capabilities)))
      (should (member "keyboard" (harness-computer-endpoint-capabilities)))
      (let (calls)
        (cl-letf (((symbol-function 'harness-computer-endpoint--output)
                   (lambda (_program args &rest _)
                     (push (cons (file-name-nondirectory (format "%s" _program)) args) calls)
                     "")))
          (harness-computer-endpoint--pointer '(:action "move" :x 12 :y 34))
          (harness-computer-endpoint--pointer '(:action "click" :button 1))
          (harness-computer-endpoint--keyboard '(:action "key" :key "Return"))
          (harness-computer-endpoint--keyboard '(:action "type" :text "hi")))
        (should (equal '(("swaymsg" "seat" "-" "cursor" "set 12 34")
                         ("swaymsg" "seat" "-" "cursor" "press button1")
                         ("swaymsg" "seat" "-" "cursor" "release button1")
                         ("wtype" "-k" "Return")
                         ("wtype" "hi"))
                       (mapcar (lambda (call)
                                 (cons (car call) (cdr call)))
                               (nreverse calls))))))))

(ert-deftest harness-computer-endpoint-window-scope-is-the-implementations ()
  "A Wayland capture can name one window when grim and swaymsg are there."
  (harness-computer-endpoint-test-with
    (harness-computer-endpoint-test-when
        'wayland '("grim" "swaymsg")
      (should (harness-computer-endpoint-window-scoped-p)))
    (harness-computer-endpoint-test-when
        'wayland '("grim")
      ;; An Emacs frame is a window too; without a display, grim alone
      ;; cannot name one.
      (cl-letf (((symbol-function 'display-graphic-p)
                 (lambda (&optional _frame) nil)))
        (should-not (harness-computer-endpoint-window-scoped-p))))))

(ert-deftest harness-computer-endpoint-id-and-secret-are-kept-private ()
  "The id is made once and stays, and the secret is 256 bits, mode 600.
Neither is part of what the client advertises with `initialize'."
  (harness-computer-endpoint-test-with
    (let ((id (harness-computer-endpoint-id)))
      (should (string-match-p "\\`cmp-[a-z0-9-]+\\'" id))
      (should (equal id (harness-computer-endpoint-id)))
      (should (file-exists-p harness-computer-endpoint-id-file)))
    (let ((secret (harness-computer-endpoint-secret)))
      (should (stringp secret))
      (should (>= (string-bytes secret) 32))
      (should (equal secret (harness-computer-endpoint-secret)))
      (should (file-exists-p harness-computer-endpoint-secret-file))
      (should (= #o600 (logand (file-modes harness-computer-endpoint-secret-file) #o777))))
    (let* ((info (harness-computer-endpoint-info))
           (capabilities (harness-computer-endpoint-client-capabilities)))
      (should (equal (harness-computer-endpoint-id) (plist-get info :id)))
      (should (equal (harness-computer-endpoint-name) (plist-get info :name)))
      (should (member "computer" (mapcar (lambda (s) (plist-get s :name))
                                         (plist-get info :servers))))
      (should (equal info (plist-get (plist-get capabilities :_harness) :computer)))
      (should-not (plist-member info :secret)))))

(ert-deftest harness-computer-endpoint-client-capabilities-keep-what-was-lent ()
  "What the client lent the harness before is still there, with the computer."
  (harness-computer-endpoint-test-with
    (let ((base (list :fs (list :readTextFile t) :terminal t)))
      (let ((capabilities (harness-computer-endpoint-client-capabilities base)))
        (should (eq t (plist-get (plist-get capabilities :fs) :readTextFile)))
        (should (eq t (plist-get capabilities :terminal)))
        (should (plist-get (plist-get capabilities :_harness) :computer))))))

;;;; The MCP server of this computer

(ert-deftest harness-computer-endpoint-answers-the-mcp-of-its-computer ()
  "The harness's MCP messages for this computer are answered, and
nothing else of the ACP connection is touched."
  (harness-computer-endpoint-test-with
    (should-not (harness-computer-endpoint-answer "_harness/other" nil nil))
    (let* ((tools (harness-computer-endpoint-test-respond
                   "_harness/computer/mcp"
                   (list :message (harness-computer-endpoint-test-mcp "tools/list"))))
           (result (plist-get (cdr tools) :result)))
      (should (car tools))
      (should (equal "2.0" (plist-get (cdr tools) :jsonrpc)))
      (should (equal 7 (plist-get (cdr tools) :id)))
      (should (member "screenshot" (mapcar (lambda (tool) (plist-get tool :name))
                                           (plist-get result :tools))))
      (should (member "clipboard" (mapcar (lambda (tool) (plist-get tool :name))
                                          (plist-get result :tools)))))))

(ert-deftest harness-computer-endpoint-refuses-mcp-for-another-computer ()
  "A message for a computer or a tool server this client does not run is an error."
  (harness-computer-endpoint-test-with
    (let ((answer (harness-computer-endpoint-test-respond
                   "_harness/computer/mcp"
                   (list :message (harness-computer-endpoint-test-mcp "tools/list"))
                   "another-box")))
      (should (car answer))
      (should (harness-acp-error-value-p (cdr answer)))
      (should (string-match-p "This computer is no another-box"
                              (harness-acp-error-value-message (cdr answer)))))
    (let ((answer (harness-computer-endpoint-test-respond
                   "_harness/computer/mcp"
                   (list :message (harness-computer-endpoint-test-mcp "tools/list"))
                   (harness-computer-endpoint-id) "other")))
      (should (harness-acp-error-value-p (cdr answer)))
      (should (string-match-p "runs no tool server named other"
                              (harness-acp-error-value-message (cdr answer)))))))

(ert-deftest harness-computer-endpoint-checks-the-token-into-the-computer ()
  "Once the harness gave a token, every MCP message must carry it."
  (harness-computer-endpoint-test-with
    (harness-computer-endpoint-set-token (harness-computer-endpoint-id) "the-token")
    (let ((missing (harness-computer-endpoint-test-respond
                    "_harness/computer/mcp"
                    (list :message (harness-computer-endpoint-test-mcp "tools/list"))
                    (harness-computer-endpoint-id) "computer" nil)))
      (should (harness-acp-error-value-p (cdr missing)))
      (should (string-match-p "no token" (harness-acp-error-value-message (cdr missing)))))
    (let ((wrong (harness-computer-endpoint-test-respond
                  "_harness/computer/mcp"
                  (list :message (harness-computer-endpoint-test-mcp "tools/list"))
                  (harness-computer-endpoint-id) "computer" "another-token")))
      (should (harness-acp-error-value-p (cdr wrong)))
      (should (string-match-p "does not match" (harness-acp-error-value-message (cdr wrong)))))
    (let ((right (harness-computer-endpoint-test-respond
                  "_harness/computer/mcp"
                  (list :message (harness-computer-endpoint-test-mcp "tools/list"))
                  (harness-computer-endpoint-id) "computer" "the-token")))
      (should (plist-get (cdr right) :result)))))

(ert-deftest harness-computer-endpoint-runs-the-computer-use-tools ()
  "A clipboard call is answered from this Emacs's selection, a tool that
cannot do it answers with an error, and a tool the server does not have
is refused by the protocol."
  (harness-computer-endpoint-test-with
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _frame) t))
              ((symbol-function 'gui-get-selection)
               (lambda (&rest _) "from the desktop")))
      (let* ((answer (harness-computer-endpoint-test-respond
                      "_harness/computer/mcp"
                      (list :message (harness-computer-endpoint-test-mcp
                                      "tools/call" '(:name "clipboard"
                                                     :arguments (:action "get"))))))
             (result (plist-get (cdr answer) :result))
             (structured (plist-get result :structuredContent)))
        (should (equal "from the desktop" (plist-get structured :text))))
      (let* ((answer (harness-computer-endpoint-test-respond
                      "_harness/computer/mcp"
                      (list :message (harness-computer-endpoint-test-mcp
                                      "tools/call" '(:name "clipboard"
                                                     :arguments (:action "bogus"))))))
             (result (plist-get (cdr answer) :result)))
        (should (harness-json-true-p (plist-get result :isError)))
        (should (string-match-p "No clipboard action" (harness-mcp-result-text result)))))
    (let ((answer (harness-computer-endpoint-test-respond
                   "_harness/computer/mcp"
                   (list :message (harness-computer-endpoint-test-mcp
                                   "tools/call" '(:name "no-such-tool" :arguments (:empty t)))))))
      (should (equal -32602 (plist-get (plist-get (cdr answer) :error) :code)))
      (should (string-match-p "Unknown tool"
                              (plist-get (plist-get (cdr answer) :error) :message))))))

;;;; Registering with a harness elsewhere

(defun harness-computer-endpoint-test-request (calls answer)
  "Return a request function recording (METHOD PARAMS) in CALLS, answering ANSWER.
ANSWER is a function of METHOD and PARAMS returning the value."
  (lambda (method params)
    (push (list method params) (car calls))
    (harness-resolved (funcall answer method params))))

(ert-deftest harness-computer-endpoint-registration-sends-what-it-runs ()
  "A registration names the computer, its secret, its resources and its
tool servers, and keeps the token the harness hands back."
  (harness-computer-endpoint-test-with
    (let* ((calls (list nil))
           (registered nil)
           (request (harness-computer-endpoint-test-request
                     calls
                     (lambda (_method _params)
                       (list :computer (list :id "cmp-box" :name "box")
                             :token "the-token")))))
      (harness-computer-endpoint-register
       request (lambda (record) (setq registered record)))
      (let* ((call (car (car calls)))
             (method (car call))
             (params (cadr call)))
        (should (equal "_harness/computer/register" method))
        (should (equal (harness-computer-endpoint-id) (plist-get (plist-get params :computer) :id)))
        (should (>= (string-bytes (plist-get params :secret)) 32))
        (should (listp (plist-get params :resources)))
        (should (equal '("computer")
                       (mapcar (lambda (s) (plist-get s :name)) (plist-get params :servers)))))
      (should (equal "cmp-box" (plist-get registered :id)))
      (should (equal "cmp-box" (harness-computer-endpoint-attached)))
      (should (equal "the-token" (harness-computer-endpoint--token-for "cmp-box"))))))

(ert-deftest harness-computer-endpoint-attach-presents-the-secret-again ()
  "An attachment names the computer and its secret, and takes the new token."
  (harness-computer-endpoint-test-with
    (let* ((calls (list nil))
           (request (harness-computer-endpoint-test-request
                     calls
                     (lambda (_method _params)
                       (list :computer (list :id "cmp-box") :token "new-token")))))
      (harness-computer-endpoint-attach request "cmp-box")
      (let* ((call (car (car calls)))
             (params (cadr call)))
        (should (equal "_harness/computer/attach" (car call)))
        (should (equal "cmp-box" (plist-get params :id)))
        (should (>= (string-bytes (plist-get params :secret)) 32)))
      (should (equal "new-token" (harness-computer-endpoint--token-for "cmp-box"))))))

(ert-deftest harness-computer-endpoint-refresh-reports-resources-again ()
  "A refresh names its computer, its resources and capabilities, and
the secret that lets it speak for the computer."
  (harness-computer-endpoint-test-with
    (let* ((calls (list nil))
           (request (harness-computer-endpoint-test-request
                     calls (lambda (_method _params) (list :id "cmp-box")))))
      (harness-computer-endpoint-set-token "cmp-box" "token")
      (harness-computer-endpoint-refresh request)
      (let* ((call (car (car calls)))
             (params (cadr call)))
        (should (equal "_harness/computer/update" (car call)))
        (should (equal "cmp-box" (plist-get params :id)))
        (should (listp (plist-get params :capabilities)))
        (should (>= (string-bytes (plist-get params :secret)) 32)))
      (harness-computer-endpoint-set-token "cmp-other" "token")
      (harness-computer-endpoint-refresh request)
      (let ((params (cadr (car (car calls)))))
        (should (equal "cmp-other" (plist-get params :id)))
        (should (plist-member params :secret))))))

(ert-deftest harness-computer-endpoint-unregister-forgets-the-token ()
  "Unregistering a computer takes it out of what this client answers for."
  (harness-computer-endpoint-test-with
    (let* ((calls (list nil))
           (request (harness-computer-endpoint-test-request
                     calls (lambda (_method _params) t))))
      (harness-computer-endpoint-set-token "cmp-box" "token")
      (harness-computer-endpoint-unregister request "cmp-box")
      (should (equal "_harness/computer/unregister" (car (car (car calls)))))
      (should-not (harness-computer-endpoint--token-for "cmp-box"))
      (should-not (harness-computer-endpoint-attached)))))

(ert-deftest harness-computer-endpoint-offers-the-git-repositories-it-finds ()
  "A repository under a resource root is offered with its own path and branch."
  (harness-computer-endpoint-test-with
    (let* ((root (file-name-as-directory (make-temp-file "harness-endpoint-root-" t)))
           (repo (expand-file-name "app/" root)))
      (unwind-protect
          (progn
            (make-directory (expand-file-name ".git" repo) t)
            (with-temp-file (expand-file-name ".git/HEAD" repo)
              (insert "ref: refs/heads/topic\n"))
            (let ((harness-computer-endpoint-resource-roots (list root)))
              (let ((resources (harness-computer-endpoint--resources)))
                (should (= 1 (length resources)))
                (should (equal "git-repo" (plist-get (car resources) :kind)))
                (should (equal "app" (plist-get (car resources) :name)))
                (should (equal (directory-file-name repo) (plist-get (car resources) :path)))
                (should (equal "topic" (plist-get (car resources) :branch))))))
        (ignore-errors (delete-directory root t))))))

(provide 'harness-computer-endpoint-test)
;;; harness-computer-endpoint-test.el ends here
