;;; harness-ui-computers.el --- The computers the harness may use, and who may use them  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The computers page: the machines the harness may use, their state,
;; their computer-use capabilities and their resources, and what the
;; current session may use there.  It talks ACP only
;; (`_harness/computer/list', `_harness/computer/access' and
;; `_harness/computer/resources'), so it shows the harness it is
;; connected to, on this machine or another, the same way.
;;
;; Viewing is not a session's permission: every client sees every
;; computer it can reach, and [View] opens the screen a computer offers
;; (its VNC page), whether or not a session may use it.  [Control] takes
;; the pointer and the keyboard from the agent until [Return]; the
;; harness refuses the agent's input on a computer a person controls,
;; and says so when a call is refused.  What a session's agent may do
;; there is a grant of the session, with a capability for each of view,
;; windows, pointer, keyboard, clipboard, audio, sandbox and exec, and
;; the page grants, revokes and narrows them.
;;
;; The page is a harness view (`harness-ui-view-map'): q buries it, g
;; refreshes, r registers this client's computer, R reports its
;; resources again, u unregisters the computer at point, V opens its
;; screen, c takes control and C gives it back, a grants it to the
;; session and x revokes it, s makes it the session's preference, and a
;; click on a capability toggles that one.  Every key has a button; ?
;; opens the menu.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-computer-endpoint)
(require 'harness-ui)

(defvar harness-ui-session-id)
(declare-function harness-ui-session "harness-ui" (id))
(declare-function harness-ui-connected-p "harness-ui" ())

(defgroup harness-ui-computers nil
  "The computers page."
  :group 'harness-ui
  :prefix "harness-ui-computers-")

(defcustom harness-ui-computers-buffer-name "*harness computers*"
  "Name of the buffer that shows the computers."
  :type 'string :group 'harness-ui-computers)

(defface harness-computers-heading-face '((t :inherit bold :height 1.05))
  "Headings of the computers page."
  :group 'harness-ui-computers)

(defface harness-computers-label-face '((t :inherit shadow))
  "Labels and secondary words of the computers page."
  :group 'harness-ui-computers)

(defface harness-computers-name-face '((t :inherit bold))
  "The names of computers."
  :group 'harness-ui-computers)

(defconst harness-ui-computers--label-column 13
  "Width of the label column of a row of the computers page.")

;;;; Buffer state

(defvar-local harness-ui-computers--computers nil
  "The computers `_harness/computer/list' answered, or nil.")
(defvar-local harness-ui-computers--access nil
  "What `_harness/computer/access' answered for the page's session, or nil.")
(defvar-local harness-ui-computers--resources nil
  "The resources `_harness/computer/resources' answered, or nil.")
(defvar-local harness-ui-computers--session nil
  "The session whose access the page shows, an id, or nil.")
(defvar-local harness-ui-computers--error nil
  "What the last request failed with, or nil.")
(defvar-local harness-ui-computers--loaded nil
  "Non-nil once an answer came for the computers.")

(defun harness-ui-computers--buffer ()
  "Return the computers buffer, making it if needed."
  (get-buffer-create harness-ui-computers-buffer-name))

(defun harness-ui-computers--session-id ()
  "Return the session whose access the page shows, or nil."
  (or harness-ui-computers--session
      (and (boundp 'harness-ui-session-id)
           (with-current-buffer (window-buffer (selected-window))
             harness-ui-session-id))
      (plist-get (car (harness-ui-user-sessions)) :id)))

;;;; Rendering

(defconst harness-ui-computers--name-column 18
  "Width of the name column of a computer row.")

(defconst harness-ui-computers--id-column 12
  "Width of the id column of a computer row.")

(defun harness-ui-computers--width ()
  "Return the width the page draws in.
It is the narrowest window of the selected frame that shows it, so the
page fits each of them; with none, the page's own width of a hundred
columns."
  (let ((windows (cl-remove-if-not
                  (lambda (window) (eq (window-buffer window) (current-buffer)))
                  (window-list (selected-frame) 'nomini))))
    (max 20 (if windows
                 (1- (apply #'min (mapcar #'window-width windows)))
               100))))

(defun harness-ui-computers--pad (text width)
  "Return TEXT in a column at least WIDTH characters wide."
  (concat text (make-string (max 2 (- width (length text))) ?\s)))

(defun harness-ui-computers--cell (text width)
  "Return TEXT as a column exactly WIDTH wide, elided when it is longer."
  (let ((text (harness-truncate-end text (max 1 (1- width)))))
    (concat text (make-string (max 1 (- width (length text))) ?\s))))

(defun harness-ui-computers--section (title width)
  "Insert TITLE as a section heading, ruled to WIDTH."
  (insert "\n " (propertize title 'face 'harness-computers-heading-face)
          " " (propertize (make-string (max 2 (- width (length title) 3)) ?─)
                          'face 'harness-computers-label-face)
          "\n"))

(defun harness-ui-computers--row (label &rest parts)
  "Insert LABEL and PARTS as a row of the page."
  (insert " " (propertize label 'face 'harness-computers-label-face)
          (make-string (max 1 (- harness-ui-computers--label-column (length label))) ?\s))
  (dolist (part parts)
    (cond ((stringp part) (insert part))
          ((functionp part) (funcall part))))
  (insert "\n"))

(defun harness-ui-computers--state-text (computer)
  "Return COMPUTER's state in a word."
  (cond ((plist-get computer :connected) (propertize "connected" 'face 'harness-success-face))
        ((eq (harness-ui-computers--sym (plist-get computer :state)) 'registered)
         (propertize "registered" 'face 'harness-dim-face))
        (t (propertize "not connected" 'face 'harness-dim-face))))

(defun harness-ui-computers--sym (value)
  "Return VALUE as a symbol, when it names one."
  (cond ((and value (symbolp value)) value)
        ((and (stringp value) (not (string-empty-p value))) (intern value))))

(defun harness-ui-computers--computer-at-point ()
  "Return the computer whose row point is on, or the only one."
  (let ((id (get-text-property (point) 'harness-ui-computers-id)))
    (or (and id (cl-find id harness-ui-computers--computers
                         :key (lambda (c) (plist-get c :id)) :test #'equal))
        (and (= (length harness-ui-computers--computers) 1)
             (car harness-ui-computers--computers))
        (and id (list :id id :name id)))))

(defun harness-ui-computers--insert-computer (computer width)
  "Insert one COMPUTER row, its name, id, kind and state, in WIDTH.
Its capabilities, resources and the person who has control follow on a
line of their own, its buttons on the next: every line fits WIDTH."
  (let ((start (point))
        (caps (plist-get computer :capability-names))
        (resources (plist-get computer :resources))
        (control (plist-get computer :control))
        (name (or (plist-get computer :name) "computer"))
        (id (or (plist-get computer :id) "")))
    (insert " ")
    (insert (harness-ui-computers--cell
             (propertize name 'face 'harness-computers-name-face)
             harness-ui-computers--name-column))
    (insert (harness-ui-computers--cell
             (propertize id 'face 'harness-computers-label-face)
             harness-ui-computers--id-column))
    (insert (harness-truncate-end
             (format "%s · %s%s"
                     (format "%s" (or (plist-get computer :kind) "client"))
                     (harness-ui-computers--state-text computer)
                     (if control (format " · control: %s" control) ""))
             (max 8 (- width 1 harness-ui-computers--name-column
                        harness-ui-computers--id-column))))
    (insert "\n ")
    (let ((rest (format "   resources: %d%s"
                        (length resources)
                        (if control (format "   control: %s" control) ""))))
      (insert (propertize "capabilities" 'face 'harness-computers-label-face) ": "
              (harness-truncate-end
               (or (and caps (string-join caps ", "))
                   (propertize "none" 'face 'harness-dim-face))
               (max 4 (- width 2 (length "capabilities") 1 (length rest))))
              rest))
    (insert "\n ")
    (harness-ui-button "[View]" (lambda () (harness-ui-computers-view computer))
                       :help "screen view of the computer at point (V)")
    (insert " ")
    (if control
        (harness-ui-button "[Return]" (lambda () (harness-ui-computers-release computer))
                           :help "control return of the computer at point (C)")
      (harness-ui-button "[Control]" (lambda () (harness-ui-computers-control computer))
                         :help "control of the computer at point (c)"))
    (insert " ")
    (harness-ui-button "[Unregistration]" (lambda () (harness-ui-computers-unregister computer))
                       :help "unregistration of the computer at point (u)")
    (insert "\n")
    (put-text-property start (point) 'harness-ui-computers-id (plist-get computer :id))))

(defun harness-ui-computers--insert-computers (width)
  "Insert the computers section, ruled to WIDTH."
  (harness-ui-computers--section "Computers" width)
  (if (null harness-ui-computers--computers)
      (insert " " (if harness-ui-computers--loaded
                      (propertize "no computer registered" 'face 'harness-dim-face)
                    (propertize "…" 'face 'harness-dim-face))
              "\n")
    (dolist (computer harness-ui-computers--computers)
      (harness-ui-computers--insert-computer computer width))))

(defun harness-ui-computers--entry (computer)
  "Return how COMPUTER stands for the page's session."
  (let ((id (plist-get computer :id)))
    (cl-find id (plist-get harness-ui-computers--access :computers)
             :key (lambda (c) (plist-get c :id)) :test #'equal)))

(defun harness-ui-computers--insert-session (width)
  "Insert the session access section, ruled to WIDTH."
  (harness-ui-computers--section "Session access" width)
  (let ((session-id (harness-ui-computers--session-id)))
    (if (null session-id)
        (insert " " (propertize "no session" 'face 'harness-dim-face) "\n")
      (let ((session (ignore-errors (harness-ui-session session-id))))
        (harness-ui-computers--row
         "Session"
         (propertize (format "%s" (or (plist-get session :name) session-id))
                     'face 'harness-computers-name-face)))
      (harness-ui-computers--row "Policy" (format "%s"
                                                  (or (plist-get harness-ui-computers--access :policy)
                                                      "auto")))
      (harness-ui-computers--row "Preferred"
                                 (or (plist-get harness-ui-computers--access :preferred)
                                     (propertize "none" 'face 'harness-dim-face)))
      (dolist (entry (plist-get harness-ui-computers--access :computers))
        (let ((computer (cl-find (plist-get entry :id) harness-ui-computers--computers
                                 :key (lambda (c) (plist-get c :id)) :test #'equal)))
          (insert " ")
          (insert (harness-ui-computers--cell
                   (propertize (or (plist-get entry :name) (plist-get entry :id))
                               'face 'harness-computers-name-face)
                   harness-ui-computers--name-column))
          (insert (if (plist-get entry :allowed)
                           (propertize (harness-truncate-end (format "allowed (%s)" (or (plist-get entry :why) "a grant"))
                                                 (max 8 (- width 1 harness-ui-computers--name-column)))
                                       'face 'harness-success-face)
                         (propertize "not allowed" 'face 'harness-dim-face)))
          (when (plist-get entry :window)
            (insert " · " (propertize (format "window %s" (plist-get entry :window))
                                      'face 'harness-computers-label-face)))
          (insert "\n ")
          (insert (propertize "capabilities" 'face 'harness-computers-label-face) ": ")
          (let ((held (plist-get entry :capabilities-allowed))
                (all (and computer (plist-get computer :capability-names))))
            (if all
                (dolist (cap all)
                  (when (and (> (current-column) 0)
                             (> (+ (current-column) 1 (string-width (format "[%s]" cap))) width))
                    (insert "\n "))
                  (harness-ui-button
                   (format "[%s]" cap)
                   (lambda () (harness-ui-computers-toggle-capability computer cap))
                   :help (format "use of %s on this computer by this session (click to toggle)"
                                 cap))
                  (insert " "))
              (insert (or (and held (string-join held ", "))
                          (propertize "none" 'face 'harness-dim-face)))))
          (insert "\n ")
          (harness-ui-button (if (plist-get entry :allowed) "[Revocation]" "[Grant]")
                             (lambda () (harness-ui-computers-toggle computer))
                             :help (if (plist-get entry :allowed)
                                       "revocation of the computer at point from this session (x)"
                                     "grant of the computer at point to this session (a)"))
          (insert " ")
          (harness-ui-button "[Preference]" (lambda () (harness-ui-computers-use computer))
                             :help "preferred computer of this session (s)")
          (insert "\n"))))))

(defun harness-ui-computers--insert-resources (width)
  "Insert the resources section, ruled to WIDTH.
A path longer than the room left is elided in the middle."
  (harness-ui-computers--section "Resources" width)
  (if (null harness-ui-computers--resources)
      (insert " " (if harness-ui-computers--loaded
                      (propertize "no resource" 'face 'harness-dim-face)
                    (propertize "…" 'face 'harness-dim-face))
              "\n")
    (dolist (resource harness-ui-computers--resources)
      (let* ((kind (format "%-10s" (harness-truncate-end (or (plist-get resource :kind) "?") 10)))
             (name (harness-ui-computers--cell
                    (or (plist-get resource :name) "?")
                    harness-ui-computers--name-column))
             (computer (harness-ui-computers--cell
                        (or (plist-get resource :computer-name)
                            (plist-get resource :computer) "")
                        harness-ui-computers--id-column))
             (path (or (plist-get resource :path) "")))
        (insert " " (propertize kind 'face 'harness-computers-label-face)
                (propertize name 'face 'harness-computers-name-face)
                (propertize computer 'face 'harness-computers-label-face))
        (unless (string-empty-p path)
          (insert (harness-truncate-middle path (max 8 (- width 1 10 harness-ui-computers--name-column harness-ui-computers--id-column)))))
        (insert "\n")))))

(defun harness-ui-computers--insert-this-client (width)
  "Insert the section about the computer this client runs on, ruled to WIDTH."
  (harness-ui-computers--section "This client" width)
  (harness-ui-computers--row "Computer"
                             (harness-computer-endpoint-name)
                             "  "
                             (if (harness-computer-endpoint-attached)
                                 (propertize "registered" 'face 'harness-success-face)
                               (propertize "not registered" 'face 'harness-dim-face)))
  (let ((capabilities (harness-computer-endpoint-capabilities)))
    (harness-ui-computers--row
     "Capabilities"
     (or (and capabilities (string-join capabilities ", "))
         (propertize "none" 'face 'harness-dim-face))))
  (insert " ")
  (harness-ui-button "[Registration]" #'harness-ui-computers-register
                     :help "registration of this computer with the harness (r)")
  (insert "  ")
  (harness-ui-button "[Resource refresh]" #'harness-ui-computers-refresh-resources
                     :help "resources of this computer reported again (R)")
  (insert "  ")
  (harness-ui-button "[Computer list]" #'harness-ui-computers-refresh
                     :help "computer list refresh (g)")
  (insert "\n"))

(defun harness-ui-computers--header ()
  "Return the header line of the page."
  (let ((computers harness-ui-computers--computers)
        (connected (cl-count-if (lambda (c) (plist-get c :connected)) harness-ui-computers--computers)))
    (list (propertize " Computers " 'face 'harness-computers-heading-face)
          (if computers
              (format "%d registered · %d connected" (length computers) connected)
            (propertize "no computer registered" 'face 'harness-dim-face))
          (if harness-ui-computers--error
              (propertize (format "  %s" harness-ui-computers--error) 'face 'harness-failure-face)
            ""))))

(defun harness-ui-computers--fit-lines (width)
  "Elide the end of every line of the page longer than WIDTH."
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (let ((start (point)) (end (line-end-position)))
        (when (> (string-width (buffer-substring-no-properties start end)) width)
          (let ((text (harness-truncate-end (buffer-substring start end) width)))
            (delete-region start end)
            (goto-char start)
            (insert text)
            (goto-char (line-end-position)))))
      (forward-line 1))))

(defun harness-ui-computers--render ()
  "Redraw the computers page."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (width (harness-ui-computers--width)))
    (erase-buffer)
    (setq header-line-format (harness-ui-computers--header))
    (insert "\n ")
    (insert (propertize "Computers" 'face 'harness-computers-heading-face))
    (insert "  " (propertize "capabilities · resources · access"
                             'face 'harness-computers-label-face)
            "\n")
    (harness-ui-computers--insert-this-client width)
    (harness-ui-computers--insert-computers width)
    (harness-ui-computers--insert-session width)
    (harness-ui-computers--insert-resources width)
    (harness-ui-computers--fit-lines width)
    (goto-char (point-min))
    (forward-line (1- (max 1 line)))))

;;;; Asking the harness

(defun harness-ui-computers--note-error (err)
  "Show ERR, a failed request, in the page and the echo area."
  (setq harness-ui-computers--error (harness-error-message err))
  (message "Harness: computers: %s" harness-ui-computers--error)
  (harness-ui-computers--render))

(defun harness-ui-computers-refresh ()
  "Fetch the computers, the session's access and the resources; redraw."
  (interactive)
  (let* ((buffer (harness-ui-computers--buffer))
         (session-id (with-current-buffer buffer (harness-ui-computers--session-id))))
    (with-current-buffer buffer
      (setq harness-ui-computers--session session-id
            harness-ui-computers--error nil))
    (harness-ui-call
     "_harness/computer/list" (and session-id (list :sessionId session-id))
     (lambda (computers)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq harness-ui-computers--computers (append computers nil)
                 harness-ui-computers--loaded t)
           (harness-ui-computers--render)))))
    (when session-id
      (harness-ui-call
       "_harness/computer/access" (list :sessionId session-id)
       (lambda (access)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq harness-ui-computers--access access)
             (harness-ui-computers--render))))
       (lambda (err)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (harness-ui-computers--note-error err))))))
    (harness-ui-call
     "_harness/computer/resources" nil
     (lambda (resources)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq harness-ui-computers--resources (append resources nil))
           (harness-ui-computers--render))))
     (lambda (err)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (harness-ui-computers--note-error err))))))
  nil)

;;;; Actions

(defun harness-ui-computers--reattach ()
  "Attach this client to its computer again, when it has one registered.
A harness that restarted reads the record back without a client; this
client presents the secret it kept, and the harness binds it again.
Nothing is registered here: a computer the harness does not know is left
for `[Registration]'."
  (when (and (harness-ui-connected-p)
             (file-exists-p harness-computer-endpoint-secret-file)
             (file-exists-p harness-computer-endpoint-id-file))
    (harness-computer-endpoint-attach
     #'harness-ui-request (harness-computer-endpoint-id)
     (lambda (_record) (harness-ui-computers-refresh))
     (lambda (_err) nil))))

(add-hook 'harness-ui-connected-hook #'harness-ui-computers--reattach)

(defun harness-ui-computers-register ()
  "Register this client's computer, and what it runs, with the harness."
  (interactive)
  (if (not (harness-ui-connected-p))
      (message "Harness: no connection")
    (harness-computer-endpoint-register
     #'harness-ui-request
     (lambda (_record)
       (message "Harness: registration")
       (harness-ui-computers-refresh))
     (lambda (err)
       (message "Harness: registration failure: %s" (harness-error-message err))
       (harness-ui-computers--render))))
  nil)

(defun harness-ui-computers-refresh-resources ()
  "Report this computer's resources again, and redraw."
  (interactive)
  (if (not (harness-ui-connected-p))
      (message "Harness: no connection")
    (harness-computer-endpoint-refresh
     #'harness-ui-request nil
     (lambda (_record)
       (message "Harness: resource refresh")
       (harness-ui-computers-refresh))
     (lambda (err)
       (message "Harness: resource refresh failure: %s" (harness-error-message err)))))
  nil)

(defun harness-ui-computers--call (method params on-ok &optional on-error)
  "Call METHOD with PARAMS over ACP; ON-OK or ON-ERROR shows a message."
  (if (not (harness-ui-connected-p))
      (message "Harness: no connection")
    (harness-ui-call
     method params
     (lambda (result)
       (when on-ok (message "%s" on-ok))
       (harness-ui-computers-refresh)
       result)
     (lambda (err)
       (message "Harness: %s" (harness-error-message err))
       (when on-error (funcall on-error err)))))
  nil)

(defun harness-ui-computers-unregister (computer)
  "Unregister COMPUTER from the harness, after a confirmation."
  (interactive (list (harness-ui-computers--computer-at-point)))
  (let ((computer (or computer (harness-ui-computers--computer-at-point))))
    (cond
     ((null computer) (message "Harness: no computer at point"))
     ((not (y-or-n-p (format "Harness: unregistration of %s " (plist-get computer :name))))
      nil)
     (t
      (harness-ui-computers--call
       "_harness/computer/unregister" (list :id (plist-get computer :id))
       (format "unregistration: %s" (plist-get computer :name))))))
  nil)

(defun harness-ui-computers-toggle (computer)
  "Grant COMPUTER to the page's session, or revoke it."
  (interactive (list (harness-ui-computers--computer-at-point)))
  (let* ((computer (or computer (harness-ui-computers--computer-at-point)))
         (session-id (harness-ui-computers--session-id))
         (entry (and computer (harness-ui-computers--entry computer))))
    (cond
     ((null computer) (message "Harness: no computer at point"))
     ((null session-id) (message "Harness: no session"))
     ((plist-get entry :allowed)
      (harness-ui-computers--call
       "_harness/computer/revoke"
       (list :sessionId session-id :computer (plist-get computer :id))
       (format "revocation: %s" (plist-get computer :name))))
     (t
      (harness-ui-computers--call
       "_harness/computer/grant"
       (list :sessionId session-id :computer (plist-get computer :id))
       (format "grant: %s" (plist-get computer :name))))))
  nil)

(defun harness-ui-computers-toggle-capability (computer capability)
  "Let the page's session use CAPABILITY on COMPUTER, or keep it from it."
  (interactive
   (let* ((computer (harness-ui-computers--computer-at-point))
          (names (plist-get computer :capability-names)))
     (list computer
           (and names (completing-read "Capability: " names nil t)))))
  (let* ((computer (or computer (harness-ui-computers--computer-at-point)))
         (session-id (harness-ui-computers--session-id))
         (entry (and computer (harness-ui-computers--entry computer)))
         (on (not (member capability (plist-get entry :capabilities-allowed)))))
    (cond
     ((null computer) (message "Harness: no computer at point"))
     ((null capability) (message "Harness: no capability"))
     ((null session-id) (message "Harness: no session"))
     (t
      (harness-ui-computers--call
       "_harness/computer/grant-capability"
       (list :sessionId session-id :computer (plist-get computer :id)
             :capability capability :on on)
       (format "%s of %s: %s" (if on "grant" "revocation") capability
               (plist-get computer :name))))))
  nil)

(defun harness-ui-computers-use (computer)
  "Make COMPUTER the page's session's preferred computer."
  (interactive (list (harness-ui-computers--computer-at-point)))
  (let* ((computer (or computer (harness-ui-computers--computer-at-point)))
         (session-id (harness-ui-computers--session-id)))
    (cond
     ((null computer) (message "Harness: no computer at point"))
     ((null session-id) (message "Harness: no session"))
     (t
      (harness-ui-computers--call
       "_harness/computer/set-preference"
       (list :sessionId session-id :computer (plist-get computer :id))
       (format "preferred computer: %s" (plist-get computer :name))))))
  nil)

(defun harness-ui-computers-view (computer)
  "Open COMPUTER's screen, the one its client shows."
  (interactive (list (harness-ui-computers--computer-at-point)))
  (let* ((computer (or computer (harness-ui-computers--computer-at-point)))
         (url (plist-get computer :vnc)))
    (cond
     ((null computer) (message "Harness: no computer at point"))
     ((null url) (message "Harness: no screen share for %s" (plist-get computer :name)))
     (t (harness-computer-endpoint-view url))))
  nil)

(defun harness-ui-computers-control (computer)
  "Take control of COMPUTER for this client, until control is given back."
  (interactive (list (harness-ui-computers--computer-at-point)))
  (let ((computer (or computer (harness-ui-computers--computer-at-point))))
    (if (null computer)
        (message "Harness: no computer at point")
      (harness-ui-computers--call
       "_harness/computer/take-control" (list :id (plist-get computer :id))
       (format "control of %s" (plist-get computer :name)))))
  nil)

(defun harness-ui-computers-release (computer)
  "Give control of COMPUTER back, so the agent may use it again."
  (interactive (list (harness-ui-computers--computer-at-point)))
  (let ((computer (or computer (harness-ui-computers--computer-at-point))))
    (if (null computer)
        (message "Harness: no computer at point")
      (harness-ui-computers--call
       "_harness/computer/release-control" (list :id (plist-get computer :id))
       (format "control return: %s" (plist-get computer :name)))))
  nil)

;;;; The page

(defvar harness-ui-computers-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map harness-ui-view-map)
    (define-key map (kbd "g") #'harness-ui-computers-refresh)
    (define-key map (kbd "r") #'harness-ui-computers-register)
    (define-key map (kbd "R") #'harness-ui-computers-refresh-resources)
    (define-key map (kbd "u") #'harness-ui-computers-unregister)
    (define-key map (kbd "a") #'harness-ui-computers-toggle)
    (define-key map (kbd "x") #'harness-ui-computers-toggle)
    (define-key map (kbd "s") #'harness-ui-computers-use)
    (define-key map (kbd "V") #'harness-ui-computers-view)
    (define-key map (kbd "c") #'harness-ui-computers-control)
    (define-key map (kbd "C") #'harness-ui-computers-release)
    (define-key map (kbd "?") #'harness-ui-menu)
    map)
  "Keys of the computers page: each key has a button on the page.")

(define-derived-mode harness-ui-computers-mode special-mode "Computers"
  "Major mode of the computers page."
  (setq-local revert-buffer-function (lambda (&rest _) (harness-ui-computers-refresh)))
  (setq-local truncate-lines t)
  (hl-line-mode 1))

(put 'harness-ui-computers-mode 'harness-menu-group
     '("Computers"
       ["This client"
        (". r" "Registration of this computer" harness-ui-computers-register)
        (". R" "Resource refresh of this computer" harness-ui-computers-refresh-resources)]
       ["Computers"
        (". g" "Computer list" harness-ui-computers-refresh)
        (". u" "Unregistration of the computer at point" harness-ui-computers-unregister)
        (". V" "Screen view of the computer at point" harness-ui-computers-view)
        (". c" "Control of the computer at point" harness-ui-computers-control)
        (". C" "Control return of the computer at point" harness-ui-computers-release)]
       ["Session access"
        (". a" "Grant of the computer at point to this session" harness-ui-computers-toggle)
        (". s" "Preferred computer of this session" harness-ui-computers-use)]))

;;;###autoload
(defun harness-computers ()
  "Show the computers the harness may use, and what this session may do there."
  (interactive)
  (let ((buffer (harness-ui-computers--buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'harness-ui-computers-mode)
        (harness-ui-computers-mode))
      (setq harness-ui-computers--session (harness-ui-computers--session-id))
      (harness-ui-computers--render))
    (harness-ui-display-view buffer)
    (with-current-buffer buffer (harness-ui-computers-refresh))
    buffer))

(defun harness-ui-computers--on-connect ()
  "Refresh every computers page after a connection, or a change."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'harness-ui-computers-mode)
        (harness-ui-computers-refresh)))))

(defvar harness-ui-computers--key "E"
  "The harness key (`harness-ui-map') that opens the computers page.
H is the thinking level of every session, so the computers are the
harness's equipment.")

(defun harness-ui-computers--init ()
  "Bind the computers page key and hear when a computer changes.  Idempotent."
  (harness-ui-bind harness-ui-computers--key #'harness-computers "Computers"
                   :group 'views :column "Views")
  (add-hook 'harness-ui-connected-hook #'harness-ui-computers--on-connect)
  (add-hook 'harness-ui-event-functions #'harness-ui-computers--on-event))

(defun harness-ui-computers--shutdown ()
  "Unbind the computers page key and stop hearing a computer change."
  (when (eq (lookup-key harness-ui-views-map (kbd harness-ui-computers--key)) #'harness-computers)
    (harness-ui-unbind harness-ui-computers--key harness-ui-views-map))
  (remove-hook 'harness-ui-connected-hook #'harness-ui-computers--on-connect)
  (remove-hook 'harness-ui-event-functions #'harness-ui-computers--on-event))

(defun harness-ui-computers--on-event (event _args)
  "Refresh every computers page when EVENT says a computer changed."
  (when (equal event "computers/changed")
    (harness-ui-computers--on-connect)))

(when (harness-module-ready-p 'ui-computers)
  (harness-ui-computers--init))

(harness-define-module 'ui-computers
  :doc "The computers page (harness-computers, E in the harness map): the machines the harness may use, their capabilities and resources, a screen view and the control toggle, and the current session's grants."
  :requires '(ui)
  :init #'harness-ui-computers--init
  :shutdown #'harness-ui-computers--shutdown)

(provide 'harness-ui-computers)
;;; harness-ui-computers.el ends here
