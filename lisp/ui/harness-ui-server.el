;;; harness-ui-server.el --- The harness server: connect to it, and see what it is  -*- lexical-binding: t; -*-

;;; Commentary:

;; The UI is a client of a harness: this Emacs's own, or a harness
;; server on another machine (`harness-server-address').  This file
;; holds the two views of that connection.
;;
;; `harness-connect-server' (C-c h c) asks for the details of the
;; server to connect to: its address, its shared secret, and whether to
;; use it whenever Emacs starts.  It is a form: the fields are edited
;; in the buffer, TAB moves between them, C-c C-c connects, and a
;; button goes back to this Emacs's own harness.  The connection it
;; makes is `harness-connect-remote', which is still the way to do it
;; from Lisp, or without the form.
;;
;; `harness-server' (C-c h C) shows the harness the UI talks to: the
;; connection, its address, how long it has been up and its round trip,
;; the harness's version and Emacs, the sessions it runs and the
;; modules it loaded.  It works the same for a server elsewhere and for
;; the harness on this machine, and asks over ACP
;; (`_harness/harness/version', `_harness/session/list' and
;; `_harness/harness/modules'), so the answer is that server's.
;;
;; Both are harness views (`harness-ui-view-map'): q buries the buffer.
;;
;; Keys of the server page: g refreshes, r connects again, c opens the
;; connection form, m lists the modules in full, w copies the address,
;; l reloads the harness and L goes back to the local one; every key has
;; a button.  The connection form is a form: C-c C-c connects, C-c C-k
;; puts the fields back, C copies the settings, and TAB moves between
;; fields and buttons.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'wid-edit)
(require 'cus-edit)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defvar harness-acp-token)
(defvar harness-process)
(defvar harness-server-address)
(declare-function harness-ui-reload-server "harness-ui")
(declare-function harness-sessions "harness-ui-sessions")

(defcustom harness-ui-server-buffer-name "*harness server*"
  "Name of the buffer that shows the harness the UI talks to."
  :type 'string :group 'harness-ui)

(defcustom harness-ui-server-connect-buffer-name "*harness connect*"
  "Name of the buffer that asks where the harness server is."
  :type 'string :group 'harness-ui)

(defface harness-server-heading-face '((t :inherit bold :height 1.05))
  "Headings of the server page and the connection form."
  :group 'harness-ui)

(defface harness-server-label-face '((t :inherit shadow))
  "Labels of the server page and the connection form."
  :group 'harness-ui)

(defface harness-server-address-face '((t :inherit fixed-pitch))
  "The address of a harness server, in the page and on the form."
  :group 'harness-ui)

(defconst harness-ui-server--label-column 13
  "Width of the label column of a row of the server page.")

;;; What the UI is connected to

(defun harness-ui-server--status (session)
  "Return the status of SESSION, a plist, as a symbol."
  (let ((status (plist-get session :status)))
    (cond ((stringp status) (intern status))
          ((symbolp status) status)
          (t nil))))

(defun harness-ui-server--state (module)
  "Return the state of MODULE, a plist, as a symbol."
  (let ((state (plist-get module :state)))
    (cond ((stringp state) (intern state))
          ((symbolp state) state)
          (t nil))))

(defun harness-ui-server--server-address ()
  "Return the address of the harness process of this Emacs, or nil.
`harness-ui--server-address' is (ADDRESS . TOKEN), and the token is
not the page's to show."
  (let ((address (bound-and-true-p harness-ui--server-address)))
    (when (consp address) (car address))))

(defun harness-ui-server--address ()
  "Return where the harness the UI talks to runs, or nil for this Emacs.
The value is an address to show, \"host:port\", or nil when the
harness runs in this Emacs."
  (pcase harness-ui-connection-address
    ('nil nil)
    ('process (or (harness-ui-server--server-address)
                  "local harness process"))
    ((and (pred stringp) address) address)))

(defun harness-ui-server--kind ()
  "Return the kind of harness the UI talks to, as a noun phrase."
  (pcase harness-ui-connection-address
    ('nil "local harness")
    ('process "harness process")
    (_ "remote server")))

(defun harness-ui-server--local-p ()
  "Non-nil when the harness the UI talks to runs in this Emacs."
  (null harness-ui-connection-address))

;;; The server page

(defvar-local harness-ui-server--version nil
  "What `_harness/harness/version' answered, a plist, or nil.")

(defvar-local harness-ui-server--sessions nil
  "The sessions the harness last listed, or nil before they arrive.")

(defvar-local harness-ui-server--sessions-loaded nil
  "Non-nil once the harness answered with its sessions, none being no sessions.")

(defvar-local harness-ui-server--modules nil
  "The modules the harness last described, or nil before they arrive.")

(defvar-local harness-ui-server--latency nil
  "Seconds the harness took to answer its version request, or nil.")

(defvar-local harness-ui-server--error nil
  "Why the harness did not answer, or nil.")

(defun harness-ui-server--buffers ()
  "Return the live server pages."
  (cl-remove-if-not (lambda (b) (with-current-buffer b (derived-mode-p 'harness-ui-server-mode)))
                    (buffer-list)))

(defun harness-ui-server--width (&optional minimum)
  "Return the width the page is drawn for.
That is its window's, never less than MINIMUM, 40 by default."
  (let ((window (get-buffer-window (current-buffer) t)))
    (max (or minimum 40) (1- (if window (window-width window) 100)))))

(defun harness-ui-server--row (label &rest parts)
  "Insert a row: LABEL in its column, then PARTS (strings, or functions inserting)."
  (insert " " (propertize (string-pad label harness-ui-server--label-column)
                          'face 'harness-server-label-face))
  (dolist (part parts)
    (if (functionp part) (funcall part) (insert part)))
  (insert "\n"))

(defun harness-ui-server--section (title width)
  "Insert the heading TITLE, ruled to WIDTH."
  (insert "\n " (propertize title 'face 'harness-server-heading-face) " "
          (propertize (make-string (max 3 (- width 4 (length title))) ?─)
                      'face 'harness-dim-face)
          "\n"))

(defun harness-ui-server--connected-text ()
  "Return the icon and words for whether the UI is connected."
  (cond ((harness-ui-connected-p)
         (concat (harness-ui-level-icon 'success)
                 (propertize " connected" 'face 'harness-success-face)))
        (harness-ui-connection
         (concat (harness-ui-level-icon 'caution)
                 (propertize " connecting" 'face 'harness-caution-face)))
        (t (concat (harness-ui-status-icon 'inactive)
                   (propertize " not connected" 'face 'harness-dim-face)))))

(defun harness-ui-server--insert-hero ()
  "Insert the line that says which harness this page is about."
  (let ((address (harness-ui-server--address))
        (dim (propertize " · " 'face 'harness-dim-face)))
    (insert "\n " (harness-ui-status-icon (if (harness-ui-connected-p) 'idle 'inactive)) " "
            (propertize (harness-ui-server--kind) 'face 'harness-server-heading-face)
            (if address
                (concat dim (propertize address 'face 'harness-server-address-face))
              "")
            "\n")))

(defun harness-ui-server--insert-connection (width)
  "Insert the connection section, ruled to WIDTH."
  (harness-ui-server--section "Connection" width)
  (harness-ui-server--row "Status" (harness-ui-server--connected-text))
  (when-let* ((address (harness-ui-server--address)))
    (harness-ui-server--row "Address"
                            (propertize address 'face 'harness-server-address-face)
                            "   "
                            (lambda ()
                              (harness-ui-button "[Address copy]" #'harness-ui-server-copy-address
                                                 :help "Address copy (w)"))))
  (when-let* ((since (and (harness-ui-connected-p) harness-ui-connected-since)))
    (harness-ui-server--row "Connected"
                            (format "%s (%s)"
                                    (harness-relative-time since)
                                    (format-time-string "%H:%M" since))))
  (harness-ui-server--row "Round trip"
                          (if harness-ui-server--latency
                              (format "%.1f ms" (* 1000 harness-ui-server--latency))
                            (propertize "…" 'face 'harness-dim-face))
                          "   "
                          (lambda ()
                            (harness-ui-button "[Measurement]" #'harness-ui-server-refresh
                                               :help "Round-trip measurement (g)"))))

(defun harness-ui-server--insert-harness (width)
  "Insert the harness section, ruled to WIDTH."
  (harness-ui-server--section "Harness" width)
  (let ((version (or (plist-get harness-ui-server--version :version)
                     (propertize "…" 'face 'harness-dim-face)))
        (emacs (plist-get harness-ui-server--version :emacs))
        (protocol (plist-get harness-ui-server--version :protocolVersion)))
    (harness-ui-server--row "Version" version)
    (harness-ui-server--row "Emacs" (or emacs (propertize "…" 'face 'harness-dim-face)))
    (harness-ui-server--row "Protocol" (if protocol (format "%s" protocol)
                                         (propertize "…" 'face 'harness-dim-face)))))

(defun harness-ui-server--insert-sessions (width)
  "Insert the sessions section, ruled to WIDTH."
  (harness-ui-server--section "Sessions" width)
  (let* ((sessions (cl-remove-if #'harness-ui-internal-session-p harness-ui-server--sessions))
         (count (lambda (status)
                  (cl-count status sessions :key #'harness-ui-server--status :test #'eq))))
    (let ((button (lambda ()
                    (harness-ui-button "[Session list]" #'harness-ui-server-open-sessions
                                       :help "Session list"))))
      (if (null sessions)
          (harness-ui-server--row "Sessions"
                                  (if harness-ui-server--sessions-loaded
                                      (propertize "none" 'face 'harness-dim-face)
                                    (propertize "…" 'face 'harness-dim-face))
                                  "   " button)
        (harness-ui-server--row
         "Sessions"
         (format "%d" (length sessions))
         (propertize " total" 'face 'harness-dim-face)
         "   "
         (concat (harness-ui-status-icon 'running) (format " %d running" (funcall count 'running)))
         "   "
         (concat (harness-ui-status-icon 'blocked) (format " %d waiting" (funcall count 'blocked)))
         "   "
         (concat (harness-ui-status-icon 'idle) (format " %d idle" (funcall count 'idle)))
         (let ((inactive (funcall count 'inactive)))
           (if (> inactive 0) (format "   %d inactive" inactive) ""))
         "   " button)))))

(defun harness-ui-server--insert-modules (width)
  "Insert the modules section, ruled to WIDTH."
  (harness-ui-server--section "Modules" width)
  (let* ((modules harness-ui-server--modules)
         (ready (cl-count 'ready modules :key #'harness-ui-server--state))
         (failed (cl-remove-if-not (lambda (m) (eq 'failed (harness-ui-server--state m))) modules)))
    (let ((button (lambda ()
                    (harness-ui-button "[Module list]" #'harness-ui-server-open-modules
                                       :help "Module list"))))
      (if (null modules)
          (harness-ui-server--row "Modules" (if harness-ui-server--modules
                                                 (propertize "none" 'face 'harness-dim-face)
                                               (propertize "…" 'face 'harness-dim-face))
                                  "   " button)
        (harness-ui-server--row "Modules"
                                (format "%d" ready)
                                (propertize " ready" 'face 'harness-dim-face)
                                (if failed
                                    (concat "   " (harness-ui-level-icon 'failure)
                                            (propertize (format " %d failed" (length failed))
                                                        'face 'harness-failure-face))
                                  (concat "   " (harness-ui-level-icon 'success)
                                          (propertize " none failed" 'face 'harness-dim-face)))
                                "   " button))
      (dolist (module failed)
        (harness-ui-server--row "" (propertize (format "%s: %s"
                                                       (plist-get module :name)
                                                       (or (plist-get module :error) "failed"))
                                               'face 'harness-failure-face))))))

(defun harness-ui-server--insert-actions ()
  "Insert the page's buttons."
  (insert " ")
  (harness-ui-button "[Connection…]" #'harness-connect-server
                     :help "Server address and token (c)")
  (insert "  ")
  (if (harness-ui-server--local-p)
      (harness-ui-button "[Module reload]" #'harness-reload
                         :help "Local module reload (l)")
    (harness-ui-button "[Reconnection]" #'harness-ui-server-reconnect
                       :help "Reconnection (r)")
    (insert "  ")
    (harness-ui-button "[Local harness]" #'harness-ui-server-use-local
                       :help "Local harness (L)")
    (insert "  ")
    (harness-ui-button "[Module reload]" #'harness-ui-server-reload
                       :help "Server module reload (l)"))
  (insert "\n"))

(defun harness-ui-server--header ()
  "Return the header line: where the UI is, and whether it is connected."
  (list (propertize " Server " 'face 'harness-server-heading-face)
        (if-let* ((address (harness-ui-server--address)))
            (propertize address 'face 'harness-server-address-face)
          (propertize "local harness" 'face 'harness-dim-face))
        "  "
        (if (harness-ui-connected-p)
            (propertize "connected" 'face 'harness-success-face)
          (propertize "not connected" 'face 'harness-dim-face))
        (if harness-ui-server--error
            (propertize (format "  %s" harness-ui-server--error) 'face 'harness-failure-face)
          "")))

(defun harness-ui-server--render ()
  "Redraw the server page from what has arrived, keeping the line."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (width (harness-ui-server--width)))
    (erase-buffer)
    (setq header-line-format (harness-ui-server--header))
    (harness-ui-server--insert-hero)
    (harness-ui-server--insert-connection width)
    (harness-ui-server--insert-harness width)
    (harness-ui-server--insert-sessions width)
    (harness-ui-server--insert-modules width)
    (insert "\n")
    (harness-ui-server--insert-actions)
    (goto-char (point-min))
    (forward-line (1- line))))

;;;; Asking the harness

(defun harness-ui-server--answer (buffer key value connected start)
  "Note VALUE for KEY in BUFFER, one answer of the harness.
CONNECTED is whether the UI was connected when the request went out,
and START when it did, for the round trip."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (pcase key
        (:version
         (setq harness-ui-server--version value)
         (when connected
           (setq harness-ui-server--latency (- (float-time) start))))
        (:sessions (setq harness-ui-server--sessions value
                             harness-ui-server--sessions-loaded t))
        (:modules (setq harness-ui-server--modules value)))
      (setq harness-ui-server--error nil)
      (harness-ui-server--render))))

(defun harness-ui-server--failed (buffer error)
  "Say in BUFFER that the harness did not answer; ERROR is why."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq harness-ui-server--error (harness-error-message error))
      (harness-ui-server--render))))

(defun harness-ui-server--refresh (&optional buffer)
  "Ask the harness for what the page shows, and redraw BUFFER as answers come.
The page first says it is asking, then shows each answer as the
harness sends it."
  (let ((buf (or buffer (current-buffer)))
        (connected (harness-ui-connected-p))
        (start (float-time)))
    (with-current-buffer buf
      (setq harness-ui-server--error nil)
      (harness-ui-server--render))
    (harness-ui-call "_harness/harness/version" nil
                     (lambda (answer)
                       (harness-ui-server--answer buf :version answer connected start))
                     (lambda (error) (harness-ui-server--failed buf error) nil))
    (harness-ui-call "_harness/session/list" nil
                     (lambda (sessions) (harness-ui-server--answer buf :sessions sessions nil nil))
                     (lambda (error) (harness-ui-server--failed buf error) nil))
    (harness-ui-call "_harness/harness/modules" nil
                     (lambda (modules) (harness-ui-server--answer buf :modules modules nil nil))
                     (lambda (error) (harness-ui-server--failed buf error) nil))))

(defun harness-ui-server--refresh-sessions (&optional buffer)
  "Ask for the sessions again, and redraw BUFFER."
  (let ((buf (or buffer (current-buffer))))
    (harness-ui-call "_harness/session/list" nil
                     (lambda (sessions)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (setq harness-ui-server--sessions sessions
                                 harness-ui-server--sessions-loaded t)
                           (harness-ui-server--render))))
                     (lambda (_) nil))))

;;;; Commands of the server page

(defun harness-ui-server-refresh ()
  "Ask the harness again for the details the page shows."
  (interactive)
  (harness-ui-server--refresh))

(defun harness-ui-server-reconnect ()
  "Connect the UI to the harness it talks to again."
  (interactive)
  (pcase harness-ui-connection-address
    ('process (harness-restart))
    ((or 'nil (pred stringp))
     (harness-connect-remote (or harness-ui-connection-address ""))
     (message "Harness: connection · %s"
              (or (and (stringp harness-ui-connection-address) harness-ui-connection-address)
                  "local harness")))))

(defun harness-ui-server-use-local ()
  "Leave the server the UI talks to, for the harness in this Emacs."
  (interactive)
  (harness-connect-remote "")
  (message "Harness: connection · local harness"))

(defun harness-ui-server-reload ()
  "Have the harness the UI talks to reload its modules."
  (interactive)
  (if (harness-ui-server--local-p)
      (harness-reload)
    (harness-ui-reload-server)))

(defun harness-ui-server-copy-address ()
  "Copy the address of the harness the UI talks to."
  (interactive)
  (let ((address (harness-ui-server--address)))
    (unless address (user-error "Local harness: no address"))
    (kill-new address)
    (message "Address copy: %s" address)))

(defun harness-ui-server-open-sessions ()
  "Show the sessions of the harness the UI talks to."
  (interactive)
  (if (fboundp 'harness-sessions)
      (harness-sessions)
    (user-error "Session list: not loaded")))

(defun harness-ui-server-open-modules ()
  "Show every module of the harness and what it does."
  (interactive)
  (harness-describe-modules))

;;;; The connection form

(defvar-local harness-ui-server--fields nil
  "Alist of the form's key and its widget, as drawn.")

(defvar-local harness-ui-server--connect-status nil
  "What the form last said about connecting, a plist (:level :text), or nil.")

(defvar-local harness-ui-server--connect-timer nil
  "Timer that watches a connection the form asked for, or nil.")

(defvar-local harness-ui-server--watch-started nil
  "When the form last asked for a connection, a float, or nil.")

(defconst harness-ui-server--watch-delay 0.3
  "Seconds between looks at a connection the form asked for.")

(defconst harness-ui-server--watch-timeout 10
  "Seconds the form waits for a connection it asked for.")

(defun harness-ui-server--stop-watch ()
  "Stop watching the connection the form asked for."
  (when (timerp harness-ui-server--connect-timer)
    (cancel-timer harness-ui-server--connect-timer))
  (setq harness-ui-server--connect-timer nil
        harness-ui-server--watch-started nil))

(defun harness-ui-server--target-p (address)
  "Non-nil when the current connection targets ADDRESS, nil for local."
  (equal (or address (harness-ui--local-address)) harness-ui-connection-address))

(defun harness-ui-server--watch-connection (buffer address)
  "Watch in BUFFER for the connection to ADDRESS to come up, or not.
ADDRESS is nil for this Emacs's own harness.  The form says it is
connecting, then says it is connected once the handshake ends, or that
no answer came when it does not in time."
  (with-current-buffer buffer
    (harness-ui-server--stop-watch)
    (setq harness-ui-server--watch-started (float-time)
          harness-ui-server--connect-timer
          (run-at-time harness-ui-server--watch-delay harness-ui-server--watch-delay
                       #'harness-ui-server--watch-tick buffer address))))

(defun harness-ui-server--watch-tick (buffer address)
  "Look at BUFFER's connection to ADDRESS once.
That is what `harness-ui-server--watch-connection' does, once."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (cond
       ((and (harness-ui-connected-p)
             (harness-ui-server--target-p address))
        (harness-ui-server--stop-watch)
        (setq harness-ui-server--connect-status
              (list :level 'success
                    :text (format "connected · %s" (or address "local harness"))))
        (harness-ui-server--render-connect))
       ((> (- (float-time) (or harness-ui-server--watch-started 0))
           harness-ui-server--watch-timeout)
        (harness-ui-server--stop-watch)
        (setq harness-ui-server--connect-status
              (list :level 'failure
                    :text (format "no answer · %s" (or address "local harness"))))
        (harness-ui-server--render-connect))))))

(defvar harness-ui-server-field-map
  (let ((map (copy-keymap custom-field-keymap)))
    (define-key map (kbd "C-c C-c") #'harness-ui-server-connect)
    (define-key map (kbd "C-c C-k") #'harness-ui-server-connect-revert)
    map)
  "Keymap of the form's fields.
RET and TAB move as in Customize, and C-c C-c connects.")

(defun harness-ui-server--install-field-map ()
  "Give every field of the form `harness-ui-server-field-map'.
Each field's overlay, and the one on the newline ending it, carries the
keymap of its type, which `cus-edit' makes `custom-field-keymap'."
  (dolist (overlay (overlays-in (point-min) (point-max)))
    (when (and (overlay-get overlay 'local-map)
               (or (overlay-get overlay 'field) (overlay-get overlay 'real-field)))
      (overlay-put overlay 'local-map harness-ui-server-field-map))))

(defun harness-ui-server--form-label (text)
  "Return TEXT as the label of a form field."
  (propertize (string-pad text 9) 'face 'harness-server-label-face))

(defun harness-ui-server--widget-value (key)
  "Return the value of the form's widget KEY, or nil."
  (when-let* ((widget (cdr (assq key harness-ui-server--fields))))
    (widget-value widget)))

(defun harness-ui-server--widget-set (key value)
  "Set the form's widget KEY to VALUE."
  (when-let* ((widget (cdr (assq key harness-ui-server--fields))))
    (widget-value-set widget value)))

(defun harness-ui-server--remembered-p ()
  "Non-nil when `harness-server-address' names a server."
  (let ((address (bound-and-true-p harness-server-address)))
    (and (stringp address) (not (string-blank-p address)))))

(defun harness-ui-server--suggested-address ()
  "Return the address the form offers: the one in use, or the saved one."
  (or (and (stringp harness-ui-connection-address) harness-ui-connection-address)
      (and (harness-ui-server--remembered-p)
           (string-trim (bound-and-true-p harness-server-address)))
      ""))

(defun harness-ui-server--connect-values ()
  "Return (ADDRESS TOKEN REMEMBER) as the form has them.
Before the form is drawn, they are the connection's own."
  (if harness-ui-server--fields
      (list (or (harness-ui-server--widget-value 'address) "")
            (or (harness-ui-server--widget-value 'token) "")
            (and (harness-ui-server--widget-value 'remember) t))
    (list (harness-ui-server--suggested-address)
          (or (bound-and-true-p harness-acp-token) "")
          (harness-ui-server--remembered-p))))

(defun harness-ui-server--connect-status-line ()
  "Return (LEVEL . TEXT) for the form's status line."
  (or (and harness-ui-server--connect-status
           (cons (plist-get harness-ui-server--connect-status :level)
                 (plist-get harness-ui-server--connect-status :text)))
      (cond ((harness-ui-connected-p)
             (cons 'success (format "connected · %s"
                                    (or (harness-ui-server--address) "local harness"))))
            (harness-ui-connection (cons 'caution "connecting"))
            (t (cons 'caution "not connected")))))

(defun harness-ui-server--render-connect ()
  "Draw the connection form, keeping what its fields hold."
  (let ((inhibit-read-only t)
        (inhibit-modification-hooks t)
        (values (harness-ui-server--connect-values)))
    (pcase-let ((`(,address ,token ,remember) values))
      (erase-buffer)
      (remove-overlays)
      ;; The fields of the drawing before this one went with their
      ;; overlays; forget them, or the next edit would find one of them
      ;; without a start, and fail in `widget-field-find'.
      (setq widget-field-new nil widget-field-list nil
            widget-field-last nil widget-field-was nil)
      (setq harness-ui-server--fields nil)
      (widget-insert "\n ")
      (widget-insert (propertize "Server connection" 'face 'harness-server-heading-face))
      (widget-insert "\n\n ")
      (widget-insert (propertize "ACP over TCP · server.example.org:4276 · scripts/harness-server"
                                 'face 'harness-dim-face))
      (widget-insert "\n")
      (push (cons 'address
                  (widget-create 'editable-field
                                 :format "  %t %v\n"
                                 :tag (harness-ui-server--form-label "Address")
                                 :help-echo "HOST:PORT"
                                 :size 44
                                 :value address))
            harness-ui-server--fields)
      (push (cons 'token
                  (widget-create 'editable-field
                                 :format "  %t %v\n"
                                 :tag (harness-ui-server--form-label "Token")
                                 :help-echo "Shared secret · optional"
                                 :size 44
                                 :value token))
            harness-ui-server--fields)
      (push (cons 'remember
                  (widget-create 'checkbox
                                 :format "  %[%v%] %t\n"
                                 :tag (propertize "Startup server"
                                                  'face 'harness-server-label-face)
                                 :help-echo (if (bound-and-true-p harness-process)
                                                "Startup address · harness-server-address"
                                              "Startup server: unavailable · harness-process nil")
                                 :value remember))
            harness-ui-server--fields)
      (setq harness-ui-server--fields (nreverse harness-ui-server--fields))
      (widget-insert "\n ")
      (widget-create 'push-button
                     :format "%[%t%]"
                     :tag "Connection"
                     :help-echo "Connection (C-c C-c)"
                     :notify (lambda (&rest _) (harness-ui-server-connect)))
      (widget-insert "  ")
      (widget-create 'push-button
                     :format "%[%t%]"
                     :tag "Local harness"
                     :help-echo "Local harness"
                     :notify (lambda (&rest _) (harness-ui-server-use-local)))
      (widget-insert "  ")
      (widget-create 'push-button
                     :format "%[%t%]"
                     :tag "Init file copy"
                     :help-echo "Init file · setq forms"
                     :notify (lambda (&rest _) (harness-ui-server-connect-copy)))
      (widget-insert "\n\n ")
      (pcase-let ((`(,level . ,text) (harness-ui-server--connect-status-line)))
        (widget-insert (harness-ui-level-icon level) " ")
        (widget-insert (propertize text 'face (harness-ui-level-face level))))
      (widget-insert "\n")
      (widget-setup)
      (harness-ui-server--install-field-map)
      (goto-char (point-min))
      (widget-forward 1))))

(defun harness-ui-server--connect-failure (error)
  "Show in the form that connecting failed, with ERROR."
  (setq harness-ui-server--connect-status
        (list :level 'failure :text (harness-error-message error))))

(defun harness-ui-server-connect ()
  "Connect the UI to the server the form holds."
  (interactive)
  (pcase-let ((`(,address ,token ,remember) (harness-ui-server--connect-values)))
    (let ((address (string-trim address))
          (token (string-trim token)))
      (cond
       ((and (not (string-empty-p address))
             (not (string-match-p "\\`\\(.*\\):\\([0-9]+\\)\\'" address)))
        (setq harness-ui-server--connect-status
              (list :level 'failure :text "address: HOST:PORT · server.example.org:4276"))
        (harness-ui-server--render-connect))
       ((and (string-empty-p address) (not (string-empty-p token)))
        (setq harness-ui-server--connect-status
              (list :level 'failure :text "address: HOST:PORT"))
        (harness-ui-server--render-connect))
       (t
        (setq harness-acp-token (and (not (string-empty-p token)) token))
        (setq harness-server-address (and remember (not (string-empty-p address)) address))
        (condition-case error
            (progn
              (harness-connect-remote address)
              (let ((target (if (string-empty-p address) nil address)))
                (if (and (harness-ui-connected-p)
                         (harness-ui-server--target-p target))
                    (setq harness-ui-server--connect-status
                          (list :level 'success
                                :text (format "connected · %s" (or target "local harness"))))
                  (setq harness-ui-server--connect-status
                        (list :level 'caution
                              :text (format "connecting · %s" (or target "local harness"))))
                  (harness-ui-server--watch-connection (current-buffer) target))))
          (error (harness-ui-server--connect-failure error)))
        (harness-ui-server--render-connect))))))

(defun harness-ui-server-connect-revert ()
  "Put the form's fields back as the connection has them."
  (interactive)
  (setq harness-ui-server--connect-status nil)
  (harness-ui-server--render-connect))

(defun harness-ui-server-connect-copy ()
  "Copy the form's values as `setq' forms for an init file."
  (interactive)
  (pcase-let ((`(,address ,token) (harness-ui-server--connect-values)))
    (let ((address (string-trim address))
          (token (string-trim token)))
      (when (and (string-empty-p address) (string-empty-p token))
        (user-error "Address: empty"))
      (kill-new
       (concat "(setq harness-server-address "
               (if (string-empty-p address) "nil" (format "%S" address))
               (unless (string-empty-p token)
                 (concat "\n      harness-acp-token " (format "%S" token)))
               ")\n"))
      (message "Init file copy · before harness-start"))))

;;;; Modes and commands

(defvar harness-ui-server-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map harness-ui-view-map)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "g") #'harness-ui-server-refresh)
    (define-key map (kbd "r") #'harness-ui-server-reconnect)
    (define-key map (kbd "c") #'harness-connect-server)
    (define-key map (kbd "m") #'harness-ui-server-open-modules)
    (define-key map (kbd "w") #'harness-ui-server-copy-address)
    (define-key map (kbd "l") #'harness-ui-server-reload)
    (define-key map (kbd "L") #'harness-ui-server-use-local)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-server-mode'.")

(define-derived-mode harness-ui-server-mode special-mode "Server"
  "Major mode of the page that shows the harness the UI talks to.
\\{harness-ui-server-mode-map}"
  (setq truncate-lines nil buffer-read-only t))

(put 'harness-ui-server-mode 'harness-menu-group
     '("Server"
       ["Page"
        (". g" "Details refresh" harness-ui-server-refresh)
        (". r" "Reconnection" harness-ui-server-reconnect)
        (". c" "Server connection…" harness-connect-server)
        (". m" "Modules" harness-ui-server-open-modules)
        (". w" "Address copy" harness-ui-server-copy-address)
        (". l" "Module reload" harness-ui-server-reload)
        (". L" "Local harness" harness-ui-server-use-local)]))

(defvar harness-ui-server-connect-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map widget-keymap)
    (define-key map [remap self-insert-command] #'harness-ui-server--no-edit)
    (define-key map (kbd "C-c C-c") #'harness-ui-server-connect)
    (define-key map (kbd "C-c C-k") #'harness-ui-server-connect-revert)
    (define-key map (kbd "C") #'harness-ui-server-connect-copy)
    (define-key map (kbd "q") #'harness-ui-quit-view)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-server-connect-mode'.")

(defun harness-ui-server--no-edit ()
  "Say where the form is edited."
  (interactive)
  (user-error "Next field: TAB · Connection: C-c C-c"))

(define-derived-mode harness-ui-server-connect-mode nil "Connection"
  "Major mode of the form that asks where the harness server is.
\\{harness-ui-server-connect-mode-map}"
  (setq truncate-lines nil
        buffer-read-only nil
        header-line-format (list (propertize " Server connection "
                                             'face 'harness-server-heading-face)))
  (setq-local widget-documentation-face 'harness-dim-face)
  (setq-local widget-button-face 'custom-button)
  (setq-local widget-button-pressed-face 'custom-button-pressed)
  (setq-local widget-mouse-face 'custom-button-mouse)
  (when custom-raised-buttons
    (setq-local widget-push-button-prefix "")
    (setq-local widget-push-button-suffix "")
    (setq-local widget-link-prefix "")
    (setq-local widget-link-suffix ""))
  (add-hook 'kill-buffer-hook #'harness-ui-server--stop-watch nil t))

(put 'harness-ui-server-connect-mode 'harness-menu-group
     '("Connection"
       ["Form"
        ("C-c C-c" "Connection" harness-ui-server-connect)
        ("C-c C-k" "Field reset" harness-ui-server-connect-revert)
        (". C" "Init file copy" harness-ui-server-connect-copy)]))

;;;###autoload
(defun harness-server ()
  "Show the harness the UI talks to, and what it is.
That is this Emacs's own harness, the harness process it started, or a
server elsewhere; the page says which, and what that harness runs."
  (interactive)
  (let ((buffer (get-buffer-create harness-ui-server-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'harness-ui-server-mode)
        (harness-ui-server-mode))
      (harness-ui-server--render))
    (harness-ui-display-view buffer)
    (harness-ui-server--refresh buffer)))

;;;###autoload
(defun harness-connect-server ()
  "Ask for a harness server's address and token, and connect the UI to it.
The form remembers the server for the next start when asked to; the
connection itself is `harness-connect-remote'."
  (interactive)
  (let ((buffer (get-buffer-create harness-ui-server-connect-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'harness-ui-server-connect-mode)
        (harness-ui-server-connect-mode))
      ;; Opening the form asks for the connection now, not for what was
      ;; typed into it the last time it was open.
      (setq harness-ui-server--fields nil
            harness-ui-server--connect-status nil)
      (harness-ui-server--render-connect))
    (harness-ui-display-view buffer)))

;;;; Following the connection

(defun harness-ui-server--redraw-all ()
  "Fetch what every server page shows again, after a reload or a connect."
  (dolist (buffer (harness-ui-server--buffers))
    (harness-ui-server--refresh buffer)))

(defun harness-ui-server--on-event (event _args)
  "Follow EVENT: the sessions a page counts change as they come and go."
  (when (member event '("session/created" "session/deleted"))
    (dolist (buffer (harness-ui-server--buffers))
      (harness-debounce (list 'harness-ui-server buffer) 0.5
                        #'harness-ui-server--refresh-sessions buffer))))

(defun harness-ui-server--init ()
  "Wire the connection form and the server page into the UI."
  (add-hook 'harness-ui-redraw-hook #'harness-ui-server--redraw-all)
  (add-hook 'harness-ui-connected-hook #'harness-ui-server--redraw-all)
  (add-hook 'harness-ui-event-functions #'harness-ui-server--on-event)
  ;; `c' was the bare prompt; the form asks for the same details.
  (define-key harness-ui-map (kbd "c") #'harness-connect-server)
  (define-key harness-ui-map (kbd "C") #'harness-server))

(defun harness-ui-server--shutdown ()
  "Unwire the pages, and their keys."
  (remove-hook 'harness-ui-redraw-hook #'harness-ui-server--redraw-all)
  (remove-hook 'harness-ui-connected-hook #'harness-ui-server--redraw-all)
  (remove-hook 'harness-ui-event-functions #'harness-ui-server--on-event)
  (when (eq (lookup-key harness-ui-map (kbd "c")) #'harness-connect-server)
    (define-key harness-ui-map (kbd "c") #'harness-connect-remote))
  (when (eq (lookup-key harness-ui-map (kbd "C")) #'harness-server)
    (define-key harness-ui-map (kbd "C") nil t)))

(harness-define-module 'ui-server
  :doc "The harness server: connect to one, and see where it runs, its version, sessions and modules."
  :requires '(ui)
  :init #'harness-ui-server--init
  :shutdown #'harness-ui-server--shutdown)

(provide 'harness-ui-server)
;;; harness-ui-server.el ends here
