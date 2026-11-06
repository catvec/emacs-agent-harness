;;; harness-ui-server-test.el --- Tests for the connection form and the server page  -*- lexical-binding: t; -*-

;;; Commentary:

;; The two views of the connection: the form that asks for a server's
;; address and token, and the page that says where the harness the UI
;; talks to runs, its version, its sessions and its modules.  The form
;; is tested against a stand-in for the connection; the page against
;; answers shaped as ACP sends them.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui-server)

(defvar harness-acp-token)
(defvar harness-process)
(defvar harness-server-address)

(defmacro harness-ui-server-test-with (&rest body)
  "Run BODY with the two server buffers made fresh, and no connection."
  (declare (indent 0))
  `(let ((harness-acp-token nil)
         (harness-server-address nil)
         (harness-process t)
         (harness-corporate-mode nil)
         (harness-ui-connection nil)
         (harness-ui-connection-address nil)
         (harness-ui-connected-since nil))
     (unwind-protect (progn ,@body)
       (dolist (name (list harness-ui-server-buffer-name
                            harness-ui-server-connect-buffer-name))
         (when (get-buffer name) (kill-buffer name))))))

(defun harness-ui-server-test-header ()
  "Return the header line of the current page as a string."
  (string-join (delq nil (mapcar (lambda (part) (and (stringp part) part))
                                 (harness-ui-server--header)))
               ""))

(defun harness-ui-server-test-text (buffer)
  "Return the text of BUFFER, a name."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-server-test-open-form ()
  "Open the connection form and return its buffer."
  (harness-connect-server)
  (get-buffer harness-ui-server-connect-buffer-name))

(defun harness-ui-server-test-set (key value)
  "Set the form's widget KEY to VALUE."
  (harness-ui-server--widget-set key value))

(defconst harness-ui-server-test-modules
  '((:name "acp" :state "ready" :doc "Agent Client Protocol")
    (:name "session" :state "ready" :doc "Sessions")
    (:name "tasks" :state "ready" :doc "Tasks")
    (:name "broken" :state "failed" :error "its requirements are not ready"))
  "Modules as `_harness/harness/modules' answers.")

(defconst harness-ui-server-test-sessions
  '((:id "a" :status "running" :kind "chat")
    (:id "b" :status "blocked" :kind "chat")
    (:id "c" :status "idle" :kind "chat")
    (:id "d" :status "idle" :kind "chat")
    (:id "e" :status "inactive" :kind "chat")
    (:id "i" :status "idle" :kind "internal"))
  "Sessions as `_harness/session/list' answers; the internal one is not counted.")

(defun harness-ui-server-test-answer (method _params)
  "Return what METHOD answers in these tests."
  (pcase method
    ("_harness/harness/version" '(:version "3.2.1" :emacs "31.1" :protocolVersion 1))
    ("_harness/session/list" harness-ui-server-test-sessions)
    ("_harness/harness/modules" harness-ui-server-test-modules)
    (_ (error "Unexpected request %s" method))))

(defmacro harness-ui-server-test-with-answers (&rest body)
  "Run BODY with ACP answering as a busy harness server would."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'harness-ui-call)
              (lambda (method params callback &optional _on-error)
                (funcall callback (harness-ui-server-test-answer method params))))
             ((symbol-function 'harness-ui-connected-p) (lambda () t)))
     ,@body))

;;;; The connection form

(ert-deftest harness-ui-server-form-shows-the-connection-in-use ()
  "The form opens on the address and token the UI connects with."
  (harness-ui-server-test-with
    (let ((harness-ui-connection-address "server.example.org:4276")
          (harness-acp-token "a-shared-secret"))
      (harness-ui-server-test-open-form)
      (let ((text (harness-ui-server-test-text harness-ui-server-connect-buffer-name)))
        (should (string-search "Server connection" text))
        (should (string-search "server.example.org:4276" text))
        (should (string-search "a-shared-secret" text))
        (should (string-search "Startup server" text)))
      (with-current-buffer harness-ui-server-connect-buffer-name
        (should (derived-mode-p 'harness-ui-server-connect-mode))
        (should (equal "server.example.org:4276" (harness-ui-server--widget-value 'address)))
        (should (equal "a-shared-secret" (harness-ui-server--widget-value 'token)))))))

(ert-deftest harness-ui-server-form-offers-the-saved-address ()
  "With no connection to copy, the form offers `harness-server-address'."
  (harness-ui-server-test-with
    (setq harness-server-address "saved.example.org:4276"
          harness-ui-connection-address 'process)
    (harness-ui-server-test-open-form)
    (with-current-buffer harness-ui-server-connect-buffer-name
      (should (equal "saved.example.org:4276" (harness-ui-server--widget-value 'address)))
      (should (harness-ui-server--widget-value 'remember)))))

(ert-deftest harness-ui-server-form-opens-on-the-connection-again ()
  "Opening the form again asks for the connection now, not what was typed."
  (harness-ui-server-test-with
    (harness-ui-server-test-open-form)
    (with-current-buffer harness-ui-server-connect-buffer-name
      (harness-ui-server-test-set 'address "old.example.org:1"))
    (setq harness-ui-connection-address "server.example.org:4276")
    (harness-ui-server-test-open-form)
    (with-current-buffer harness-ui-server-connect-buffer-name
      (should (equal "server.example.org:4276" (harness-ui-server--widget-value 'address))))))

(ert-deftest harness-ui-server-form-stays-editable-after-a-drawing ()
  "The fields take what is typed after the form is drawn again."
  (harness-ui-server-test-with
    (harness-ui-server-test-open-form)
    (with-current-buffer harness-ui-server-connect-buffer-name
      (harness-ui-server-test-set 'address "127.0.0.1:4276")
      ;; Connecting draws the form again; so does putting it back.
      (harness-ui-server-connect-revert)
      (harness-ui-server-test-set 'address "127.0.0.1:4277")
      (should (equal "127.0.0.1:4277" (harness-ui-server--widget-value 'address))))))

(ert-deftest harness-ui-server-form-connects-with-what-it-holds ()
  "Connect sends the typed address and token, and remembers the server."
  (harness-ui-server-test-with
    (let ((asked nil))
      (harness-ui-server-test-open-form)
      (with-current-buffer harness-ui-server-connect-buffer-name
        (harness-ui-server-test-set 'address " 127.0.0.1:4276 ")
        (harness-ui-server-test-set 'token " a-shared-secret ")
        (harness-ui-server-test-set 'remember t)
        (cl-letf (((symbol-function 'harness-connect-remote)
                   (lambda (address)
                     (push address asked)
                     (setq harness-ui-connection-address address)))
                  ((symbol-function 'harness-ui-connected-p) (lambda () t)))
          (harness-ui-server-connect))
        (should (equal '("127.0.0.1:4276") asked))
        (should (equal "127.0.0.1:4276" harness-server-address))
        (should (equal "a-shared-secret" harness-acp-token))
        (should (string-search "connected · 127.0.0.1:4276" (harness-ui-server-test-text (current-buffer))))))))

(ert-deftest harness-ui-server-form-remembers-no-server-when-unticked ()
  "Without the checkbox, connecting does not change the next start."
  (harness-ui-server-test-with
    (harness-ui-server-test-open-form)
    (with-current-buffer harness-ui-server-connect-buffer-name
      (harness-ui-server-test-set 'address "127.0.0.1:4276")
      (harness-ui-server-test-set 'remember nil)
      (cl-letf (((symbol-function 'harness-connect-remote)
                 (lambda (address) (setq harness-ui-connection-address address)))
                ((symbol-function 'harness-ui-connected-p) (lambda () t)))
        (harness-ui-server-connect))
      (should-not harness-server-address))))

(ert-deftest harness-ui-server-form-connects-to-the-local-harness-when-empty ()
  "An empty address goes back to this Emacs's own harness."
  (harness-ui-server-test-with
    (let ((asked 'none))
      (harness-ui-server-test-open-form)
      (with-current-buffer harness-ui-server-connect-buffer-name
        (harness-ui-server-test-set 'address "")
        (harness-ui-server-test-set 'token "")
        (cl-letf (((symbol-function 'harness-connect-remote)
                   (lambda (address)
                     (setq asked address)
                     (setq harness-ui-connection-address 'process)))
                  ((symbol-function 'harness-ui-connected-p) (lambda () t)))
          (harness-ui-server-connect))
        (should (equal "" asked))
        (should-not harness-server-address)
        (should-not harness-acp-token)
        (should (equal '(success . "connected · local harness")
                       (harness-ui-server--connect-status-line)))
        (should-not harness-ui-server--connect-timer)))))

(ert-deftest harness-ui-server-form-refuses-an-address-without-a-port ()
  "An address that is not HOST:PORT is refused before any connection."
  (harness-ui-server-test-with
    (let ((asked 0))
      (harness-ui-server-test-open-form)
      (with-current-buffer harness-ui-server-connect-buffer-name
        (harness-ui-server-test-set 'address "server.example.org")
        (cl-letf (((symbol-function 'harness-connect-remote)
                   (lambda (_) (cl-incf asked))))
          (harness-ui-server-connect))
        (should (zerop asked))
        (should (string-search "HOST:PORT" (harness-ui-server-test-text (current-buffer))))))))

(ert-deftest harness-ui-server-form-shows-why-connecting-failed ()
  "A failed connection stays on the form, with the reason."
  (harness-ui-server-test-with
    (harness-ui-server-test-open-form)
    (with-current-buffer harness-ui-server-connect-buffer-name
      (harness-ui-server-test-set 'address "127.0.0.1:4276")
      (cl-letf (((symbol-function 'harness-connect-remote)
                 (lambda (_) (user-error "The harness cannot be reached"))))
        (harness-ui-server-connect))
      (should (string-search "The harness cannot be reached" (harness-ui-server-test-text (current-buffer)))))))

(ert-deftest harness-ui-server-form-copies-the-init-file-forms ()
  "Copy for the init file writes the `setq' that makes the connection."
  (harness-ui-server-test-with
    (harness-ui-server-test-open-form)
    (with-current-buffer harness-ui-server-connect-buffer-name
      (harness-ui-server-test-set 'address "server.example.org:4276")
      (harness-ui-server-test-set 'token "a-shared-secret")
      (harness-ui-server-connect-copy)
      (should (string-search "(setq harness-server-address \"server.example.org:4276\""
                             (current-kill 0)))
      (should (string-search "harness-acp-token \"a-shared-secret\"" (current-kill 0))))))

;;;; The server page

(ert-deftest harness-ui-server-page-shows-a-server-elsewhere ()
  "The page says where the harness runs, its version, its sessions and its modules."
  (harness-ui-server-test-with
    (harness-ui-server-test-with-answers
      (setq harness-ui-connection-address "server.example.org:4276")
      (harness-server)
      (let ((text (harness-ui-server-test-text harness-ui-server-buffer-name)))
        (should (string-search "remote server · server.example.org:4276" text))
        (should (string-search "connected" text))
        (should (string-search "3.2.1" text))
        (should (string-search "31.1" text))
        (should (string-search "5 total" text))
        (should (string-search "1 running" text))
        (should (string-search "1 waiting" text))
        (should (string-search "2 idle" text))
        (should (string-search "3 ready" text))
        (should (string-search "1 failed" text))
        (should (string-search "broken: its requirements are not ready" text)))
      (with-current-buffer harness-ui-server-buffer-name
        (should (derived-mode-p 'harness-ui-server-mode))))))

(ert-deftest harness-ui-server-page-never-shows-the-token ()
  "The address of the harness process is its address, not its secret.
`harness-ui--server-address' keeps (ADDRESS . TOKEN); only the address
is the page's to show."
  (harness-ui-server-test-with
    (let ((harness-ui--server-address '("127.0.0.1:4281" . "a-shared-secret")))
      (should (equal "127.0.0.1:4281" (harness-ui-server--server-address)))
      (should-not (string-search "a-shared-secret" (harness-ui-server--server-address))))))

(ert-deftest harness-ui-server-page-does-not-count-internal-sessions ()
  "A session the harness made for itself is not one the page counts."
  (harness-ui-server-test-with
    (harness-ui-server-test-with-answers
      (setq harness-ui-connection-address "server.example.org:4276")
      (harness-server)
      ;; Six sessions came, one of them internal.
      (should (string-search "5 total" (harness-ui-server-test-text harness-ui-server-buffer-name))))))

(ert-deftest harness-ui-server-page-shows-the-local-harness ()
  "Without a server, the page says the harness runs in this Emacs."
  (harness-ui-server-test-with
    (harness-ui-server-test-with-answers
      (setq harness-ui-connection-address nil)
      (harness-server)
      (let ((text (harness-ui-server-test-text harness-ui-server-buffer-name)))
        (should (string-search "local harness" text))
        (should (string-search "connected" text))
        (should-not (string-search "Address" text))
        (should (string-search "3.2.1" text))))))

(ert-deftest harness-ui-server-page-says-when-the-harness-did-not-answer ()
  "An unanswered page keeps its last text and says why in the header."
  (harness-ui-server-test-with
    (cl-letf (((symbol-function 'harness-ui-call)
               (lambda (_method _params _callback &optional on-error)
                 (funcall on-error (harness-rejected "the connection closed"))))
              ((symbol-function 'harness-ui-connected-p) (lambda () nil)))
      (setq harness-ui-connection-address "server.example.org:4276")
      (harness-server)
      (with-current-buffer harness-ui-server-buffer-name
        (should (string-search "connection closed" (harness-ui-server-test-header)))))))

;;;; Copy inventory: exact labels, headers, tooltips and status transitions

(defun harness-ui-server-test-help-echoes (buffer)
  "Return the string tooltips of BUFFER, sorted and without duplicates."
  (with-current-buffer buffer
    (let ((pos (point-min)) help)
      (while (< pos (point-max))
        (let ((text (get-text-property pos 'help-echo)))
          (when (stringp text) (push text help)))
        (setq pos (next-single-property-change pos 'help-echo nil (point-max))))
      (dolist (overlay (overlays-in (point-min) (point-max)))
        (let ((text (overlay-get overlay 'help-echo)))
          (when (stringp text) (push text help))))
      (sort (delete-dups help) #'string<))))

(defun harness-ui-server-test-copy-lines (text)
  "Return TEXT's nonblank lines without layout padding or section rules."
  (delq nil
        (mapcar (lambda (line)
                  (let ((text (string-trim
                               (replace-regexp-in-string
                                "[ \t]+" " " (replace-regexp-in-string "─+" "" line)))))
                    (unless (string-empty-p text) text)))
                (split-string text "\n"))))

(defmacro harness-ui-server-test-with-copy (&rest body)
  "Run BODY with icons and widget decoration out of the copy inventory."
  (declare (indent 0))
  `(harness-ui-server-test-with
     (let ((custom-raised-buttons nil))
       (cl-letf (((symbol-function 'harness-ui-level-icon) (lambda (_) ""))
                 ((symbol-function 'harness-ui-status-icon) (lambda (_) "")))
         ,@body))))

(defun harness-ui-server-test-form-copy (address token status)
  "Check all authored copy of the form with ADDRESS, TOKEN and STATUS."
  (should (equal (append '("Server connection"
                           "ACP over TCP · server.example.org:4276 · scripts/harness-server")
                         (list (string-trim (concat "Address " address))
                               (string-trim (concat "Token " token)))
                         '("[ ] Startup server"
                           "Connection Local harness Init file copy")
                         (list status))
                 (harness-ui-server-test-copy-lines (buffer-string))))
  (should (equal '("Server connection")
                 (harness-ui-server-test-copy-lines (string-join header-line-format ""))))
  (should (equal (sort (list "HOST:PORT" "Shared secret · optional"
                            (if harness-process
                                "Startup address · harness-server-address"
                              "Startup server: unavailable · harness-process nil")
                            "Connection (C-c C-c)" "Local harness"
                            "Init file · setq forms") #'string<)
                 (harness-ui-server-test-help-echoes (current-buffer)))))

(ert-deftest harness-ui-server-form-copy-inventory ()
  "All form text is a reviewed label, including its two startup hints."
  (harness-ui-server-test-with-copy
    (dolist (process '(t nil))
      (let ((harness-process process))
        (with-current-buffer (harness-ui-server-test-open-form)
          (harness-ui-server-test-form-copy "" "" "not connected"))))
    (let ((harness-ui-connection 'pending))
      (with-current-buffer (harness-ui-server-test-open-form)
        (harness-ui-server-test-form-copy "" "" "connecting")))
    (cl-letf (((symbol-function 'harness-ui-connected-p) (lambda () t)))
      (dolist (case '((nil . "local harness") (process . "local harness process")
                      ("server.example.org:4276" . "server.example.org:4276")))
        (let ((harness-ui-connection-address (car case))
              (harness-ui--server-address nil))
          (with-current-buffer (harness-ui-server-test-open-form)
            (harness-ui-server-test-form-copy
             (if (stringp (car case)) (car case) "") ""
             (concat "connected · " (cdr case)))))))))

(ert-deftest harness-ui-server-form-status-copy-inventory ()
  "Connecting, success and timeout have labels for remote and local targets."
  (harness-ui-server-test-with-copy
    (let (connected)
      (cl-letf (((symbol-function 'harness-ui-connected-p) (lambda () connected))
                ((symbol-function 'harness-connect-remote)
                 (lambda (address)
                   (setq harness-ui-connection-address
                         (if (string-empty-p address) (harness-ui--local-address) address))))
                ;; Drive the watch explicitly; no timers or ten-second sleeps.
                ((symbol-function 'run-at-time) (lambda (&rest _) nil)))
        (dolist (target '("server.example.org:4276" nil))
          (dolist (outcome '(success timeout))
            (setq connected nil)
            (let ((address (or target "")) (label (or target "local harness")))
              (with-current-buffer (harness-ui-server-test-open-form)
                (harness-ui-server-test-set 'address address)
                (harness-ui-server-connect)
                (harness-ui-server-test-form-copy address "" (concat "connecting · " label))
                (if (eq outcome 'success)
                    (setq connected t)
                  (setq harness-ui-server--watch-started
                        (- (float-time) harness-ui-server--watch-timeout 1)))
                (harness-ui-server--watch-tick (current-buffer) target)
                (harness-ui-server-test-form-copy
                 address "" (concat (if connected "connected · " "no answer · ") label))
                (should-not harness-ui-server--watch-started)))))))))

(ert-deftest harness-ui-server-form-validation-copy-inventory ()
  "Validation and corporate refusals stay labels; server payloads stay intact."
  (harness-ui-server-test-with-copy
    (with-current-buffer (harness-ui-server-test-open-form)
      (harness-ui-server-test-set 'address "server.example.org")
      (harness-ui-server-connect)
      (harness-ui-server-test-form-copy "server.example.org" ""
                                        "address: HOST:PORT · server.example.org:4276")
      (harness-ui-server-test-set 'address "")
      (harness-ui-server-test-set 'token "a-secret")
      (harness-ui-server-connect)
      (harness-ui-server-test-form-copy "" "a-secret" "address: HOST:PORT")
      (harness-ui-server-test-set 'address "server.example.org:4276")
      (let ((harness-corporate-mode t)) (harness-ui-server-connect))
      (harness-ui-server-test-form-copy "server.example.org:4276" "a-secret"
                                        "Corporate mode · local harness only")
      (harness-ui-server--connect-failure '(error "The server refused this token."))
      (should (equal '(failure . "The server refused this token.")
                     (harness-ui-server--connect-status-line))))))

(ert-deftest harness-ui-server-page-copy-inventory ()
  "The whole server page, header and tooltips use the reviewed noun labels."
  (harness-ui-server-test-with-copy
    (harness-ui-server-test-with-answers
      (dolist (case '(("server.example.org:4276" . "remote server · server.example.org:4276")
                      (process . "harness process · 127.0.0.1:4276")
                      (nil . "local harness")))
        (let* ((harness-ui-connection-address (car case))
               (harness-ui--server-address '("127.0.0.1:4276" . "secret"))
               (address (if (eq (car case) 'process) "127.0.0.1:4276" (car case))))
          (harness-server)
          (with-current-buffer harness-ui-server-buffer-name
            (setq harness-ui-server--latency 0.002)
            (harness-ui-server--render)
            (should (equal
                     (append (list (cdr case) "Connection" "Status connected")
                             (when address (list (concat "Address " address " [Address copy]")))
                             '("Round trip 2.0 ms [Measurement]"
                               "Harness" "Version 3.2.1" "Emacs 31.1" "Protocol 1"
                               "Sessions" "Sessions 5 total 1 running 1 waiting 2 idle 1 inactive [Session list]"
                               "Modules" "Modules 3 ready 1 failed [Module list]"
                               ;; ACP data, not authored interface copy.
                               "broken: its requirements are not ready")
                             (list (if address
                                       "[Connection…] [Reconnection] [Local harness] [Module reload]"
                                     "[Connection…] [Module reload]")))
                     (harness-ui-server-test-copy-lines (buffer-string))))
            (should (equal (list (concat "Server " (or address "local harness") " connected"))
                           (harness-ui-server-test-copy-lines (harness-ui-server-test-header))))
            (should (equal
                     (seq-sort #'string<
                               (append '("Round-trip measurement (g)" "Session list" "Module list"
                                         "Server address and token (c)")
                                       (if address
                                           '("Address copy (w)" "Reconnection (r)" "Local harness (L)"
                                             "Server module reload (l)")
                                         '("Local module reload (l)"))))
                     (harness-ui-server-test-help-echoes (current-buffer))))))))))

(ert-deftest harness-ui-server-page-loading-and-empty-copy-inventory ()
  "The disconnected, loading and empty states contain no extra prose."
  (harness-ui-server-test-with-copy
    (with-temp-buffer
      (harness-ui-server-mode)
      (setq harness-ui-connection-address "server.example.org:4276")
      (harness-ui-server--render)
      (should (equal '("remote server · server.example.org:4276"
                       "Connection" "Status not connected"
                       "Address server.example.org:4276 [Address copy]"
                       "Round trip … [Measurement]"
                       "Harness" "Version …" "Emacs …" "Protocol …"
                       "Sessions" "Sessions … [Session list]"
                       "Modules" "Modules … [Module list]"
                       "[Connection…] [Reconnection] [Local harness] [Module reload]")
                     (harness-ui-server-test-copy-lines (buffer-string))))
      (should (equal " Server server.example.org:4276  not connected"
                     (harness-ui-server-test-header)))
      (setq harness-ui-server--sessions-loaded t)
      (harness-ui-server--render)
      (should (member "Sessions none [Session list]"
                      (harness-ui-server-test-copy-lines (buffer-string))))
      (harness-ui-server--failed (current-buffer) '(error "The connection was refused."))
      (should (equal " Server server.example.org:4276  not connected  The connection was refused."
                     (harness-ui-server-test-header))))))

(ert-deftest harness-ui-server-command-copy-inventory ()
  "Echo-area copy and local command errors are noun labels too."
  (harness-ui-server-test-with-copy
    (with-current-buffer (harness-ui-server-test-open-form)
      (let (echo)
        (cl-letf (((symbol-function 'message)
                   (lambda (format-string &rest args)
                     (setq echo (apply #'format-message format-string args))))
                  ((symbol-function 'harness-connect-remote) #'ignore))
          (harness-ui-server-use-local)
          (should (equal "Harness: connection · local harness" echo))
          (let ((harness-ui-connection-address "server.example.org:4276"))
            (harness-ui-server-reconnect)
            (should (equal "Harness: connection · server.example.org:4276" echo))
            (harness-ui-server-copy-address)
            (should (equal "Address copy: server.example.org:4276" echo)))
          (harness-ui-server-test-set 'address "server.example.org:4276")
          (harness-ui-server-connect-copy)
          (should (equal "Init file copy · before harness-start" echo))))
      (pcase-dolist (`(,command . ,copy)
                     '((harness-ui-server--no-edit . "Next field: TAB · Connection: C-c C-c")
                       (harness-ui-server-copy-address . "Local harness: no address")))
        (should (equal copy (error-message-string (should-error (funcall command) :type 'user-error)))))
      (harness-ui-server-test-set 'address "")
      (should (equal "Address: empty"
                     (error-message-string (should-error (harness-ui-server-connect-copy) :type 'user-error)))))))

(ert-deftest harness-ui-server-reload-matches-the-local-button ()
  "The reload key and the local button reach the same command."
  (harness-ui-server-test-with
    (let (reloaded)
      (cl-letf (((symbol-function 'harness-reload) (lambda () (push 'local reloaded)))
                ((symbol-function 'harness-ui-reload-server) (lambda () (push 'server reloaded))))
        (harness-ui-server-reload)
        (setq harness-ui-connection-address "server.example.org:4276")
        (harness-ui-server-reload)
        (should (equal '(server local) reloaded))))))

(ert-deftest harness-ui-server-menu-copy-inventory ()
  "Menus have the same noun labels as the views."
  (should (equal '("Server"
                   ["Page"
                    (". g" "Details refresh" harness-ui-server-refresh)
                    (". r" "Reconnection" harness-ui-server-reconnect)
                    (". c" "Server connection…" harness-connect-server)
                    (". m" "Modules" harness-ui-server-open-modules)
                    (". w" "Address copy" harness-ui-server-copy-address)
                    (". l" "Module reload" harness-ui-server-reload)
                    (". L" "Local harness" harness-ui-server-use-local)])
                 (get 'harness-ui-server-mode 'harness-menu-group)))
  (should (equal '("Connection"
                   ["Form"
                    ("C-c C-c" "Connection" harness-ui-server-connect)
                    ("C-c C-k" "Field reset" harness-ui-server-connect-revert)
                    (". C" "Init file copy" harness-ui-server-connect-copy)])
                 (get 'harness-ui-server-connect-mode 'harness-menu-group))))

(provide 'harness-ui-server-test)
;;; harness-ui-server-test.el ends here
