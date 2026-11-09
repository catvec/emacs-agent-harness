;;; harness-ui-computers-test.el --- Tests for the computers page  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness.

;;; Commentary:

;; The computers page (harness-ui-computers.el): what it draws, word for
;; word -- its headings, labels, states, buttons and tooltips -- and what
;; its keys, its command and its event hook do.  It talks ACP only, so the
;; answers are put into the buffer the way an answer would arrive.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)

(defvar harness-acp--server-enabled nil)
(defvar harness-ui-computers--computers)
(defvar harness-ui-computers--access)
(defvar harness-ui-computers--resources)
(defvar harness-ui-computers--session)
(defvar harness-ui-computers--loaded)
(defvar harness-ui-computers--error)
(declare-function harness-ui-computers--buffer "harness-ui-computers" ())
(declare-function harness-ui-computers--render "harness-ui-computers" ())
(declare-function harness-ui-computers--header "harness-ui-computers" ())
(declare-function harness-ui-computers-refresh "harness-ui-computers" ())
(declare-function harness-ui-computers--on-event "harness-ui-computers" (event args))

(defconst harness-ui-computers-test-modules
  '(store project config provider provider-demo tools session agent tools-agent perms readonly mcp acp
    computers tools-computers ui ui-computers)
  "The modules every test loads.")

(defmacro harness-ui-computers-test-with (&rest body)
  "Load the UI and the computers, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (setq harness-acp--server-enabled nil)
     (dolist (m harness-ui-computers-test-modules)
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (let ((harness-computer-endpoint--attached nil)
           (harness-computer-endpoint--id nil)
           (harness-computer-endpoint-name "this-computer")
           (default-directory (harness-test-temp-dir)))
       (with-current-buffer (harness-ui-computers--buffer)
         (harness-ui-computers-mode)
         (setq harness-ui-computers--computers nil
               harness-ui-computers--access nil
               harness-ui-computers--resources nil
               harness-ui-computers--session nil
               harness-ui-computers--loaded nil
               harness-ui-computers--error nil))
       ;; What this machine can do is data, and differs from one to the
       ;; next; the page's words are what is tried here.
       (cl-letf (((symbol-function 'harness-computer-endpoint-capabilities)
                  (lambda () nil)))
         ,@body))))

(defun harness-ui-computers-test-computer (id name &rest props)
  "Return a computer record ID NAME with PROPS, as `computer/list' gives it.
A key in PROPS replaces the one the record has already: a plist's first
key is the one read."
  (let ((base (list :id id :name name :kind 'client :state 'connected :connected t
                    :host "example.test" :capability-names '("view" "pointer")
                    :capabilities (list (list :name "view" :doc "See the screen")
                                        (list :name "pointer" :doc "Move the pointer"))
                    :servers '("computer") :resources nil)))
    (dolist (key '(:id :name :kind :state :connected :host
                   :capability-names :capabilities :servers :resources :control))
      (when (plist-member props key)
        (setq base (harness-plist-remove base key))))
    (append base props)))

(defun harness-ui-computers-test-draw (&rest state)
  "Draw the page with STATE, a plist of the buffer's answers, and return its text.
The text has no properties, so it is the words a person reads."
  (with-current-buffer (harness-ui-computers--buffer)
    (when (plist-member state :computers)
      (setq harness-ui-computers--computers (plist-get state :computers)
            harness-ui-computers--loaded t))
    (when (plist-member state :access)
      (setq harness-ui-computers--access (plist-get state :access)))
    (when (plist-member state :resources)
      (setq harness-ui-computers--resources (plist-get state :resources)))
    (when (plist-member state :session)
      (setq harness-ui-computers--session (plist-get state :session)))
    (harness-ui-computers--render)
    (substring-no-properties (buffer-string))))

(defun harness-ui-computers-test-header ()
  "Return the page's header line as the words a person reads."
  (with-current-buffer (harness-ui-computers--buffer)
    (mapconcat (lambda (part) (substring-no-properties (format "%s" part)))
               (harness-ui-computers--header) "")))

(defun harness-ui-computers-test-help (label)
  "Return the tooltip of the button LABEL on the page, or nil.
LABEL is matched as it is written: [view] is not [View]."
  (with-current-buffer (harness-ui-computers--buffer)
    (let ((case-fold-search nil))
      (goto-char (point-min))
      (when (search-forward label nil t)
        (get-text-property (match-beginning 0) 'help-echo)))))

(defun harness-ui-computers-test-session-answer ()
  "Return an access answer for a session that may use its client's computer."
  (list :session "sid-1" :policy 'auto :preferred nil :revoked nil
        :computers (list (list :id "cmp-desk" :name "workstation" :kind 'client
                               :state 'connected :connected t
                               :allowed t :why "the client's computer"
                               :capabilities-allowed '("view" "pointer"))
                         (list :id "cmp-box" :name "box" :kind 'client
                               :state 'connected :connected t
                               :allowed nil :why nil
                               :capabilities-allowed nil))
        :available '("cmp-desk" "cmp-box")))

;;;; What the page says

(ert-deftest harness-ui-computers-page-draws-every-section-and-label ()
  "The page's headings, labels and sections are the words of its inventory."
  (harness-ui-computers-test-with
    (cl-letf (((symbol-function 'harness-ui-session)
               (lambda (_id) (list :id "sid-1" :name "Session one"))))
      (let ((text (harness-ui-computers-test-draw
                   :computers (list (harness-ui-computers-test-computer
                                     "cmp-desk" "workstation"
                                     :capability-names '("view" "pointer")
                                     :resources nil)
                                    (harness-ui-computers-test-computer
                                     "cmp-box" "box" :state 'disconnected :connected nil
                                     :capability-names '("view")
                                     :resources (list (list :kind "git-repo" :name "app"
                                                            :path "/srv/app"))
                                     :control "user"))
                   :access (harness-ui-computers-test-session-answer)
                   :resources (list (list :kind "git-repo" :name "app" :computer "cmp-box"
                                          :computer-name "box" :path "/srv/app"))
                   :session "sid-1")))
        ;; The hero and the sections.
        (should (string-match-p "Computers  capabilities · resources · access" text))
        (should (string-match-p "\n This client " text))
        (should (string-match-p "\n Computers " text))
        (should (string-match-p "\n Session access " text))
        (should (string-match-p "\n Resources " text))
        ;; This client.
        (should (string-match-p "Computer     this-computer  not registered" text))
        (should (string-match-p "Capabilities none" text))
        ;; Computers: name, id, kind, state, capabilities, resources, buttons.
        (should (string-match-p "workstation       cmp-desk    client · connected" text))
        (should (string-match-p "box               cmp-box     client · not connected" text))
        (should (string-match-p "capabilities: view, pointer   resources: 0" text))
        (should (string-match-p "capabilities: view   resources: 1   control: user" text))
        (should (string-match-p "control: user" text))
        (should (string-match-p "\\[View\\]" text))
        (should (string-match-p "\\[Control\\]" text))
        (should (string-match-p "\\[Return\\]" text))
        (should (string-match-p "\\[Unregistration\\]" text))
        ;; Session access.
        (should (string-match-p "Session      Session one" text))
        (should (string-match-p "Policy       auto" text))
        (should (string-match-p "Preferred    none" text))
        (should (string-match-p "workstation       allowed (the client's computer)" text))
        (should (string-match-p "box               not allowed" text))
        (should (string-match-p "\\[view\\]" text))
        (should (string-match-p "\\[Revocation\\]" text))
        (should (string-match-p "\\[Grant\\]" text))
        (should (string-match-p "\\[Preference\\]" text))
        ;; Resources.
        (should (string-match-p "git-repo  app               box         /srv/app" text))))))

(ert-deftest harness-ui-computers-nothing-overflows-a-narrow-window ()
  "Every line fits the width of a narrow window, elided where it must be."
  (harness-ui-computers-test-with
    (cl-letf (((symbol-function 'harness-ui-session)
               (lambda (_id) (list :id "sid-1" :name "Session one")))
              ((symbol-function 'harness-ui-computers--width) (lambda () 60)))
      (harness-ui-computers-test-draw
       :computers (list (harness-ui-computers-test-computer
                         "cmp-desk" "a-computer-with-a-long-name"
                         :capability-names '("view" "pointer" "keyboard" "clipboard" "audio")
                         :resources nil)
                        (harness-ui-computers-test-computer
                         "cmp-box-with-a-long-id" "box" :state 'disconnected :connected nil
                         :capability-names '("view")
                         :resources (list (list :kind "git-repository" :name "a-repository-with-a-long-name"
                                               :path "/srv/a/very/long/path/that/should/be/elided"))
                         :control "some-user"))
       :access (harness-ui-computers-test-session-answer)
       :resources (list (list :kind "git-repository" :name "a-repository-with-a-long-name"
                              :computer "cmp-box-with-a-long-id"
                              :computer-name "box"
                              :path "/srv/a/very/long/path/that/should/be/elided"))
       :session "sid-1")
      (with-current-buffer (harness-ui-computers--buffer)
        (dolist (line (split-string (buffer-string) "\n"))
          (should (<= (string-width line) 60)))))))

(ert-deftest harness-ui-computers-page-says-what-is-empty ()
  "Nothing registered, no session and no resource each read as what they are."
  (harness-ui-computers-test-with
    ;; An answer with nothing in it, not a page still waiting for one.
    (let ((text (harness-ui-computers-test-draw :computers nil :resources nil)))
      (should (string-match-p "no computer registered" text))
      (should (string-match-p "no session" text))
      (should (string-match-p "no resource" text))
      (should (string-match-p "Computer     this-computer  not registered" text)))
    (should (string-match-p "no computer registered" (harness-ui-computers-test-header)))))

(ert-deftest harness-ui-computers-header-counts-what-is-there ()
  "The header counts the computers and the connected ones, and says an error."
  (harness-ui-computers-test-with
    (harness-ui-computers-test-draw
     :computers (list (harness-ui-computers-test-computer "cmp-desk" "workstation")
                      (harness-ui-computers-test-computer "cmp-box" "box"
                                                          :state 'disconnected :connected nil)))
    (should (equal " Computers 2 registered · 1 connected"
                   (harness-ui-computers-test-header)))
    (with-current-buffer (harness-ui-computers--buffer)
      (setq harness-ui-computers--error "the harness is not connected")
      (should (string-match-p "  the harness is not connected"
                              (harness-ui-computers-test-header))))))

;;;; What the buttons say they do

(ert-deftest harness-ui-computers-tooltips-are-noun-phrases ()
  "Every button has the tooltip its inventory gives it."
  (harness-ui-computers-test-with
    (cl-letf (((symbol-function 'harness-ui-session)
               (lambda (_id) (list :id "sid-1" :name "Session one"))))
      (harness-ui-computers-test-draw
       :computers (list (harness-ui-computers-test-computer "cmp-desk" "workstation")
                        (harness-ui-computers-test-computer "cmp-box" "box" :control "user"))
       :access (harness-ui-computers-test-session-answer)
       :session "sid-1")
      (should (equal "registration of this computer with the harness (r)"
                     (harness-ui-computers-test-help "[Registration]")))
      (should (equal "resources of this computer reported again (R)"
                     (harness-ui-computers-test-help "[Resource refresh]")))
      (should (equal "computer list refresh (g)"
                     (harness-ui-computers-test-help "[Computer list]")))
      (should (equal "screen view of the computer at point (V)"
                     (harness-ui-computers-test-help "[View]")))
      (should (equal "control of the computer at point (c)"
                     (harness-ui-computers-test-help "[Control]")))
      (should (equal "control return of the computer at point (C)"
                     (harness-ui-computers-test-help "[Return]")))
      (should (equal "unregistration of the computer at point (u)"
                     (harness-ui-computers-test-help "[Unregistration]")))
      (should (equal "grant of the computer at point to this session (a)"
                     (harness-ui-computers-test-help "[Grant]")))
      (should (equal "revocation of the computer at point from this session (x)"
                     (harness-ui-computers-test-help "[Revocation]")))
      (should (equal "preferred computer of this session (s)"
                     (harness-ui-computers-test-help "[Preference]")))
      (should (equal "use of view on this computer by this session (click to toggle)"
                     (harness-ui-computers-test-help "[view]"))))))

(ert-deftest harness-ui-computers-menu-is-noun-phrases ()
  "The page's menu lists its keys under noun headings with noun descriptions."
  (harness-ui-computers-test-with
    (let* ((group (get 'harness-ui-computers-mode 'harness-menu-group))
           (columns (cdr group))
           (entries (cl-loop for column in columns
                             append (cl-loop for item in (append column nil)
                                             when (consp item) collect item))))
      (should (equal "Computers" (car group)))
      (should (equal '("This client" "Computers" "Session access")
                     (mapcar (lambda (column) (aref column 0)) columns)))
      (should (equal '(". r" ". R" ". g" ". u" ". V" ". c" ". C" ". a" ". s")
                     (mapcar #'car entries)))
      (should (equal '("Registration of this computer"
                       "Resource refresh of this computer"
                       "Computer list"
                       "Unregistration of the computer at point"
                       "Screen view of the computer at point"
                       "Control of the computer at point"
                       "Control return of the computer at point"
                       "Grant of the computer at point to this session"
                       "Preferred computer of this session")
                     (mapcar #'cadr entries)))
      (dolist (entry entries)
        (should (fboundp (nth 2 entry)))
        ;; The menu teaches the page's own key.
        (should (eq (nth 2 entry)
                    (lookup-key harness-ui-computers-mode-map
                                (kbd (string-remove-prefix ". " (car entry))))))))))

;;;; The keys, the command and the event

(ert-deftest harness-ui-computers-the-key-is-bound-and-unbound-with-the-module ()
  "E opens the page while the module is ready, and the module's keys are the page's."
  (harness-ui-computers-test-with
    (should (eq (lookup-key harness-ui-map (kbd "E")) #'harness-computers))
    (should (eq (lookup-key harness-ui-computers-mode-map (kbd "r"))
                #'harness-ui-computers-register))
    (should (eq (lookup-key harness-ui-computers-mode-map (kbd "g"))
                #'harness-ui-computers-refresh))
    (should (eq (lookup-key harness-ui-computers-mode-map (kbd "u"))
                #'harness-ui-computers-unregister))
    (harness-ui-computers--shutdown)
    (should-not (lookup-key harness-ui-map (kbd "E")))))

(ert-deftest harness-ui-computers-the-command-opens-the-page-and-refreshes ()
  "The command shows a buffer in the page's mode and asks the harness."
  (harness-ui-computers-test-with
    (let ((shown nil) (refreshed nil))
      (cl-letf (((symbol-function 'harness-ui-display-view)
                 (lambda (buffer) (setq shown buffer)))
                ((symbol-function 'harness-ui-computers-refresh)
                 (lambda () (setq refreshed t))))
        (let ((buffer (harness-computers)))
          (should (eq buffer shown))
          (should refreshed)
          (with-current-buffer buffer
            (should (derived-mode-p 'harness-ui-computers-mode))))))))

(ert-deftest harness-ui-computers-a-change-refreshes-every-open-page ()
  "A computers/changed event refreshes open pages, and no other event does."
  (harness-ui-computers-test-with
    (let ((buffer (harness-ui-computers--buffer))
          (refreshed 0))
      (with-current-buffer buffer
        (harness-ui-computers-mode))
      (cl-letf (((symbol-function 'harness-ui-computers-refresh)
                 (lambda () (cl-incf refreshed))))
        (harness-ui-computers--on-event "computers/changed" nil)
        (should (= 1 refreshed))
        (harness-ui-computers--on-event "access/changed" nil)
        (should (= 1 refreshed))))))

;;;; Acting on no computer

(ert-deftest harness-ui-computers-an-action-with-no-computer-says-so ()
  "The page's commands name what they lack, and send nothing."
  (harness-ui-computers-test-with
    (harness-ui-computers-test-draw :computers nil :resources nil)
    (let ((sent nil) (said nil))
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (&rest _) (setq sent t)))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq said (apply #'format format-string args)))))
        (harness-ui-computers-unregister nil)
        (should (equal "Harness: no computer at point" said))
        (setq said nil)
        (harness-ui-computers-toggle nil)
        (should (equal "Harness: no computer at point" said))
        (setq said nil)
        (harness-ui-computers-use nil)
        (should (equal "Harness: no computer at point" said))
        (setq said nil)
        (harness-ui-computers-view nil)
        (should (equal "Harness: no computer at point" said))
        (setq said nil)
        (harness-ui-computers-control nil)
        (should (equal "Harness: no computer at point" said))
        (should-not sent)))))

(provide 'harness-ui-computers-test)
;;; harness-ui-computers-test.el ends here
