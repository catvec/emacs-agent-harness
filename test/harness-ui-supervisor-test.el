;;; harness-ui-supervisor-test.el --- Tests for supervisor mode in the UI  -*- lexical-binding: t; -*-
;;; Commentary:

;; The chat header's supervisor segment for a session the supervisor
;; plugin governs (supervising, hands-on) and for one it does not (no
;; segment), the click and the V key that toggle the mode through
;; `_harness/supervisor/set', what the toggle says when the harness has
;; no supervisor module, when a session is not governed or not known,
;; and the module's key and header hook, added and removed again.
;;
;; `harness-set-supervisor-all' (the menu's V) is here too: it asks on
;; or off, changes every governed session through
;; `_harness/supervisor/set-all' with the everything filter, makes the
;; mode the default for new work unless a prefix argument says
;; otherwise, says how many sessions changed and what still overrides
;; the defaults, and says plainly when the module is not there.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)

(defvar harness-acp-token)
(defvar harness-acp--server-enabled)
(defvar harness-ui--sessions)
(defvar harness-ui-map)
(defvar harness-ui-session-id)
(defvar harness-ui-setting-target-function)
(defvar harness-chat-header-functions)

(declare-function harness-chat--header "harness-ui-chat")
(declare-function harness-chat--header-prefix "harness-ui-chat")
(declare-function harness-toggle-supervisor "harness-ui-supervisor")
(declare-function harness-set-supervisor-all "harness-ui-supervisor")
(declare-function harness-ui-supervisor--header "harness-ui-supervisor")
(declare-function harness-ui-supervisor--failed "harness-ui-supervisor")
(declare-function harness-ui-supervisor--init "harness-ui-supervisor")
(declare-function harness-ui-supervisor--shutdown "harness-ui-supervisor")

(defmacro harness-ui-supervisor-test-with (&rest body)
  "Load the UI, its chat and the supervisor module, then run BODY.
The ACP module loads first, with its server off, as the UI requires it."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (harness-test-load-module 'acp))
     (let ((harness-acp-token nil)
           (default-directory dir))
       (harness-test-load-module 'ui)
       (harness-test-load-module 'ui-chat)
       (harness-test-load-module 'ui-supervisor)
       (clrhash harness-ui--sessions)
       (unwind-protect (progn ,@body)
         (harness-ui-supervisor--shutdown)
         (clrhash harness-ui--sessions)))))

(defun harness-ui-supervisor-test-session (id ext)
  "Cache session ID, whose :ext plist is EXT, as the UI keeps sessions."
  (puthash id (list :id id :name "Work" :status "idle" :ext ext) harness-ui--sessions))

(defmacro harness-ui-supervisor-test-chat (id &rest body)
  "Run BODY in a chat buffer of session ID, shown in the selected window."
  (declare (indent 1))
  `(save-window-excursion
     (with-temp-buffer
       (setq-local harness-ui-session-id ,id)
       (set-window-buffer (selected-window) (current-buffer))
       ,@body)))

(defun harness-ui-supervisor-test-messages (thunk)
  "Call THUNK and return the messages it shows, oldest first."
  (let (out)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) out))))
      (funcall thunk))
    (nreverse out)))

(ert-deftest harness-ui-supervisor-segment-on-off-and-absent ()
  "The segment says supervisor or hands-on for a governed session, else nothing.
Each state carries its face and its help, and a session never governed has none."
  (harness-ui-supervisor-test-with
    (harness-ui-supervisor-test-chat "s1"
      (harness-ui-supervisor-test-session "s1" '(:supervisor t))
      (let ((seg (harness-ui-supervisor--header)))
        (should (equal "supervisor " (substring-no-properties seg)))
        (should (eq 'harness-supervisor-face (get-text-property 0 'face seg)))
        (should (equal "Supervisor mode: this session plans and delegates to workers on cheaper models; it cannot change files itself (mouse-1: let it work hands-on)"
                       (get-text-property 0 'help-echo seg))))
      (harness-ui-supervisor-test-session "s1" '(:supervisor :false))
      (let ((seg (harness-ui-supervisor--header)))
        (should (equal "hands-on " (substring-no-properties seg)))
        (should (eq 'harness-dim-face (get-text-property 0 'face seg)))
        (should (equal "Hands-on: this session may change files itself (mouse-1: back to supervisor mode)"
                       (get-text-property 0 'help-echo seg))))
      ;; Sub-agents and side conversations carry no :supervisor at all.
      (harness-ui-supervisor-test-session "s1" nil)
      (should-not (harness-ui-supervisor--header))
      (harness-ui-supervisor-test-session "s1" '(:other 1))
      (should-not (harness-ui-supervisor--header))
      ;; A chat whose session is not known shows nothing either.
      (clrhash harness-ui--sessions)
      (should-not (harness-ui-supervisor--header)))))

(ert-deftest harness-ui-supervisor-segment-leads-the-header ()
  "The segment comes first in the header line, through the header hook."
  (harness-ui-supervisor-test-with
    (harness-ui-supervisor-test-session "s1" '(:supervisor t))
    (harness-ui-supervisor-test-chat "s1"
      (should (equal "supervisor " (substring-no-properties (harness-chat--header-prefix))))
      (should (string-prefix-p "supervisor" (substring-no-properties (harness-chat--header most-positive-fixnum)))))
    (harness-ui-supervisor-test-session "s2" nil)
    (harness-ui-supervisor-test-chat "s2"
      (should (equal "" (harness-chat--header-prefix))))))

(ert-deftest harness-ui-supervisor-toggle-sends-the-flip ()
  "Toggling a supervising session turns it hands-on, and back again.
Each toggle sends `_harness/supervisor/set' and says what it changed."
  (harness-ui-supervisor-test-with
    (let (sent)
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (method params callback &optional _on-error)
                   (push (list method params) sent)
                   (funcall callback (list :id "s1" :ext (list :supervisor (plist-get params :on)))))))
        (harness-ui-supervisor-test-session "s1" '(:supervisor t))
        (should (equal '("Supervisor mode off (hands-on)")
                       (harness-ui-supervisor-test-messages (lambda () (harness-toggle-supervisor "s1")))))
        (should (equal '(("_harness/supervisor/set" (:sessionId "s1" :on :false))) sent))
        (setq sent nil)
        (harness-ui-supervisor-test-session "s1" '(:supervisor :false))
        (should (equal '("Supervisor mode on")
                       (harness-ui-supervisor-test-messages (lambda () (harness-toggle-supervisor "s1")))))
        (should (equal '(("_harness/supervisor/set" (:sessionId "s1" :on t))) sent))))))

(ert-deftest harness-ui-supervisor-click-toggles-the-chat-session ()
  "A click on the segment toggles the session of its chat, as V does."
  (harness-ui-supervisor-test-with
    (let (sent)
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (method params callback &optional _on-error)
                   (push (list method params) sent)
                   (funcall callback nil))))
        (harness-ui-supervisor-test-session "s1" '(:supervisor :false))
        (harness-ui-supervisor-test-chat "s1"
          (let* ((seg (harness-ui-supervisor--header))
                 (click (lookup-key (get-text-property 0 'local-map seg) [mouse-1])))
            (should (equal "hands-on " (substring-no-properties seg)))
            (should (equal '("Supervisor mode on")
                           (harness-ui-supervisor-test-messages
                            (lambda ()
                              (funcall click (list 'mouse-1 (list (selected-window) 'header-line '(0 . 0) 0)))))))
            (should (equal '(("_harness/supervisor/set" (:sessionId "s1" :on t))) sent))))))))

(ert-deftest harness-ui-supervisor-missing-method-says-so ()
  "A harness without the supervisor module says it is not available."
  (harness-ui-supervisor-test-with
    (harness-ui-supervisor-test-session "s1" '(:supervisor t))
    (dolist (err (list '(acp-error -32601 "Method not found: _harness/supervisor/set" nil)
                       (list 'harness-no-such-method "_harness/supervisor/set")))
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (_method _params _callback &optional on-error)
                   (funcall on-error err))))
        (should (equal '("Supervisor mode is not available (the supervisor module is not loaded)")
                       (harness-ui-supervisor-test-messages (lambda () (harness-toggle-supervisor "s1")))))))))

(ert-deftest harness-ui-supervisor-other-failures-are-shown ()
  "Any other failure is shown with its message; a replaced connection is not."
  (harness-ui-supervisor-test-with
    (harness-ui-supervisor-test-session "s1" '(:supervisor t))
    (cl-letf (((symbol-function 'harness-ui-call)
               (lambda (_method _params _callback &optional on-error)
                 (funcall on-error '(acp-error -32000 "Session s1 is a sub-agent" nil)))))
      (should (equal '("Harness: supervisor mode failed: Session s1 is a sub-agent")
                     (harness-ui-supervisor-test-messages (lambda () (harness-toggle-supervisor "s1"))))))
    (cl-letf (((symbol-function 'harness-ui-call)
               (lambda (_method _params _callback &optional on-error)
                 (funcall on-error '(acp-error -32000 "Session s1 is a sub-agent" nil))))
              ((symbol-function 'harness-ui-connection-replaced-p) (lambda (_err) t)))
      (should-not (harness-ui-supervisor-test-messages (lambda () (harness-toggle-supervisor "s1")))))))

(ert-deftest harness-ui-supervisor-toggle-leaves-other-sessions-alone ()
  "A session the plugin does not govern is said so, and nothing is sent."
  (harness-ui-supervisor-test-with
    (let (sent)
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (&rest args) (push args sent))))
        (harness-ui-supervisor-test-session "sub" nil)
        (should (equal '("Supervisor mode does not govern this session: sub-agents and side conversations never supervise")
                       (harness-ui-supervisor-test-messages (lambda () (harness-toggle-supervisor "sub")))))
        (harness-ui-supervisor-test-session "btw" '(:other 1))
        (should (equal '("Supervisor mode does not govern this session: sub-agents and side conversations never supervise")
                       (harness-ui-supervisor-test-messages (lambda () (harness-toggle-supervisor "btw")))))
        ;; A session the harness has not sent yet is not known, not ungoverned.
        (should (equal '("Supervisor mode: the harness has not sent this session yet")
                       (harness-ui-supervisor-test-messages (lambda () (harness-toggle-supervisor "nope")))))
        ;; A task that has not started has no session to supervise.
        (with-temp-buffer
          (setq-local harness-ui-setting-target-function
                      (lambda () (cons '(:model "demo:scripted") #'ignore)))
          (should (equal '("Supervisor mode applies to a session, not to a task that has not started yet")
                         (harness-ui-supervisor-test-messages
                          (lambda () (call-interactively #'harness-toggle-supervisor))))))
        (should-not sent)))))

(ert-deftest harness-ui-supervisor-key-and-hook ()
  "The module binds V in the harness keys and adds its header function once.
Shut down, both go again."
  (harness-ui-supervisor-test-with
    (should (harness-module-ready-p 'ui-supervisor))
    (should (eq #'harness-toggle-supervisor (lookup-key harness-ui-map (kbd "V"))))
    (should (memq #'harness-ui-supervisor--header harness-chat-header-functions))
    ;; Starting again, as a reload does, adds nothing.
    (harness-ui-supervisor--init)
    (should (eq #'harness-toggle-supervisor (lookup-key harness-ui-map (kbd "V"))))
    (should (= 1 (cl-count #'harness-ui-supervisor--header harness-chat-header-functions)))
    (harness-ui-supervisor--shutdown)
    (should-not (lookup-key harness-ui-map (kbd "V")))
    (should-not (memq #'harness-ui-supervisor--header harness-chat-header-functions))))

;;;; Turning the mode on or off for every session

(ert-deftest harness-ui-supervisor-set-all-changes-and-sets-the-defaults ()
  "The command asks on first, changes every governed session through
`_harness/supervisor/set-all' with the everything filter, makes the mode
the default for new sessions and new tasks, and says how many sessions
changed; a project's .dir-locals.el that still says otherwise is named."
  (harness-ui-supervisor-test-with
    (let ((calls nil) (said nil) (offered nil))
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (method params &optional callback _on-error)
                   (push (cons method params) calls)
                   (when callback
                     (funcall callback
                              (cond ((equal method "_harness/supervisor/set-all") '("s1" "s2" "s3"))
                                    ((equal method "_harness/config/overrides")
                                     '(:key "harness-supervisor" :value "t"
                                       :files ((:file "/p/.dir-locals.el" :scope "project" :dir "/p/"
                                                      :project "p" :value "nil"))))
                                    (t nil))))))
                ((symbol-function 'message)
                 (lambda (format-string &rest args) (push (apply #'format format-string args) said)))
                ((symbol-function 'completing-read)
                 (lambda (_prompt table _pred require _initial _hist def)
                   (setq offered (list (all-completions "" table)
                                       (completion-metadata-get (completion-metadata "" table nil)
                                                                'display-sort-function)
                                       require def))
                   def)))
        (call-interactively #'harness-set-supervisor-all))
      ;; On first, as offered.
      (should (equal '(("on" "off") identity t "on") offered))
      ;; The sessions first, then the two defaults, then what overrides them.
      (should (equal '("_harness/supervisor/set-all" "_harness/config/set" "_harness/config/set"
                       "_harness/config/overrides")
                     (reverse (mapcar #'car calls))))
      (should (equal '(:on t :filter (:active t :tasks t))
                     (cdr (assoc "_harness/supervisor/set-all" calls))))
      (should (equal '(("harness-supervisor" . "t") ("harness-supervisor-tasks" . "t"))
                     (mapcar (lambda (call)
                               (cons (plist-get (cdr call) :key) (plist-get (cdr call) :value)))
                             (reverse (cl-remove-if-not (lambda (call)
                                                          (equal (car call) "_harness/config/set"))
                                                        calls)))))
      (dolist (call (cl-remove-if-not (lambda (call) (equal (car call) "_harness/config/set")) calls))
        (should (eq t (plist-get (cdr call) :printed)))
        (should (equal "global" (plist-get (cdr call) :scope))))
      (should (equal '(:key "harness-supervisor" :value "t" :printed t :dirs nil)
                     (cdr (assoc "_harness/config/overrides" calls))))
      (should (equal (list (concat "Supervisor mode on for 3 sessions, and for new sessions and the open"
                                   " boards' new tasks.  But new sessions in p start hands-on"
                                   " (harness-supervisor in /p/.dir-locals.el); M-x harness-settings"
                                   " changes them."))
                     said))
      ;; Off, saying what still supervises new work.
      (setq calls nil said nil)
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (method params &optional callback _on-error)
                   (push (cons method params) calls)
                   (when callback
                     (funcall callback
                              (cond ((equal method "_harness/supervisor/set-all") '("s1"))
                                    ((equal method "_harness/config/overrides")
                                     '(:key "harness-supervisor" :value "nil"
                                       :files ((:file "/q/.dir-locals.el" :scope "project" :dir "/q/"
                                                      :project "q" :value "t"))))
                                    (t nil))))))
                ((symbol-function 'message)
                 (lambda (format-string &rest args) (push (apply #'format format-string args) said)))
                ((symbol-function 'completing-read) (lambda (&rest _) "off")))
        (harness-set-supervisor-all))
      (should (equal '(:on :false :filter (:active t :tasks t))
                     (cdr (assoc "_harness/supervisor/set-all" calls))))
      (should (equal '(("harness-supervisor" . "nil") ("harness-supervisor-tasks" . "nil"))
                     (mapcar (lambda (call)
                               (cons (plist-get (cdr call) :key) (plist-get (cdr call) :value)))
                             (reverse (cl-remove-if-not (lambda (call)
                                                          (equal (car call) "_harness/config/set"))
                                                        calls)))))
      (should (equal (list (concat "Supervisor mode off for 1 session, and for new sessions and the open"
                                   " boards' new tasks.  But new sessions in q supervise"
                                   " (harness-supervisor in /q/.dir-locals.el); M-x harness-settings"
                                   " changes them."))
                     said)))))

(ert-deftest harness-ui-supervisor-set-all-prefix-leaves-the-defaults-alone ()
  "With a prefix argument the sessions change but the defaults for new
sessions and new tasks stay as they were, and nothing is said about them."
  (harness-ui-supervisor-test-with
    (let ((calls nil) (said nil))
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (method params &optional callback _on-error)
                   (push (cons method params) calls)
                   (when callback (funcall callback (and (equal method "_harness/supervisor/set-all") '("s1"))))))
                ((symbol-function 'message)
                 (lambda (format-string &rest args) (push (apply #'format format-string args) said)))
                ((symbol-function 'completing-read) (lambda (&rest _) "on")))
        (harness-set-supervisor-all t))
      (should (equal '(:on t :filter (:active t :tasks t))
                     (cdr (assoc "_harness/supervisor/set-all" calls))))
      (should-not (assoc "_harness/config/set" calls))
      (should-not (assoc "_harness/config/overrides" calls))
      (should (equal '("Supervisor mode on for 1 session") said)))))

(ert-deftest harness-ui-supervisor-set-all-says-when-the-module-is-missing ()
  "A harness without the supervisor module is told so plainly, as the
toggle does; nothing is reported as changed."
  (harness-ui-supervisor-test-with
    (let (said)
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (_method _params _callback &optional on-error)
                   (funcall on-error '(acp-error -32601 "Method not found: _harness/supervisor/set-all" nil))))
                ((symbol-function 'message)
                 (lambda (format-string &rest args) (push (apply #'format format-string args) said)))
                ((symbol-function 'completing-read) (lambda (&rest _) "on")))
        (harness-set-supervisor-all))
      (should (equal '("Supervisor mode is not available (the supervisor module is not loaded)")
                     said)))))

(provide 'harness-ui-supervisor-test)
;;; harness-ui-supervisor-test.el ends here
