;;; harness-ui-supervisor-test.el --- Tests for supervisor mode in the UI  -*- lexical-binding: t; -*-
;;; Commentary:

;; The chat header's supervisor segment for a session the supervisor
;; plugin governs (supervising, hands-on) and for one it does not (no
;; segment), the click and the V key that toggle the mode through
;; `_harness/supervisor/set', what the toggle says when the harness has
;; no supervisor module, when a session is not governed or not known,
;; and the module's key and header hook, added and removed again.

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

(provide 'harness-ui-supervisor-test)
;;; harness-ui-supervisor-test.el ends here
