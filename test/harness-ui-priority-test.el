;;; harness-ui-priority-test.el --- Tests for session priority in the UI  -*- lexical-binding: t; -*-
;;; Commentary:

;; The chat header's priority segment for a session at low or high
;; priority and for one at the default (no segment), the click and the p
;; key that set it through `_harness/priority/set', what setting it says
;; when the harness has no priority module or knows no such session, and
;; the module's key and header hook, added and removed again.

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

(declare-function harness-set-priority "harness-ui-priority")
(declare-function harness-ui-priority--header "harness-ui-priority")
(declare-function harness-ui-priority--init "harness-ui-priority")
(declare-function harness-ui-priority--shutdown "harness-ui-priority")

(defmacro harness-ui-priority-test-with (&rest body)
  "Load the UI, its chat and the priority module, then run BODY.
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
       (harness-test-load-module 'ui-priority)
       (clrhash harness-ui--sessions)
       (unwind-protect (progn ,@body)
         (harness-ui-priority--shutdown)
         (clrhash harness-ui--sessions)))))

(defun harness-ui-priority-test-session (id ext)
  "Cache session ID, whose :ext plist is EXT, as the UI keeps sessions."
  (puthash id (list :id id :name "Work" :status "idle" :ext ext) harness-ui--sessions))

(defmacro harness-ui-priority-test-chat (id &rest body)
  "Run BODY in a chat buffer of session ID, shown in the selected window."
  (declare (indent 1))
  `(save-window-excursion
     (with-temp-buffer
       (setq-local harness-ui-session-id ,id)
       (set-window-buffer (selected-window) (current-buffer))
       ,@body)))

(defun harness-ui-priority-test-messages (thunk)
  "Call THUNK and return the messages it shows, oldest first."
  (let (out)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) out))))
      (funcall thunk))
    (nreverse out)))

(defmacro harness-ui-priority-test-recording (&rest body)
  "Run BODY with `harness-ui-call' recorded in `sent' and answered at once.
Each call is pushed as (METHOD PARAMS) onto the `sent' of the test, and
its callback is given the priority it was sent, as the method answers."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'harness-ui-call)
              (lambda (method params callback &optional _on-error)
                (push (list method params) sent)
                (funcall callback (plist-get params :priority)))))
     ,@body))

(ert-deftest harness-ui-priority-segment-high-low-and-default ()
  "The segment says priority: high or low; the default shows nothing.
Each state carries its face and its help, and a session whose priority
the harness never sent has no segment."
  (harness-ui-priority-test-with
    (harness-ui-priority-test-chat "s1"
      (harness-ui-priority-test-session "s1" '(:priority "high"))
      (let ((seg (harness-ui-priority--header)))
        (should (equal "priority: high " (substring-no-properties seg)))
        (should (eq 'harness-priority-high-face (get-text-property 0 'face seg)))
        (should (equal "Priority high: the harness serves this session's commands before lower ones' (mouse-1: change the priority)"
                       (get-text-property 0 'help-echo seg))))
      (harness-ui-priority-test-session "s1" '(:priority "low"))
      (let ((seg (harness-ui-priority--header)))
        (should (equal "priority: low " (substring-no-properties seg)))
        (should (eq 'harness-priority-low-face (get-text-property 0 'face seg)))
        (should (equal "Priority low: the harness serves this session's commands before lower ones' (mouse-1: change the priority)"
                       (get-text-property 0 'help-echo seg))))
      ;; The default, a session the harness has sent nothing about, and
      ;; one whose priority this UI does not know.
      (harness-ui-priority-test-session "s1" '(:priority "medium"))
      (should-not (harness-ui-priority--header))
      (harness-ui-priority-test-session "s1" '(:other 1))
      (should-not (harness-ui-priority--header))
      (harness-ui-priority-test-session "s1" nil)
      (should-not (harness-ui-priority--header))
      (harness-ui-priority-test-session "s1" '(:priority "urgent"))
      (should-not (harness-ui-priority--header))
      ;; A chat whose session is not known shows nothing either.
      (clrhash harness-ui--sessions)
      (should-not (harness-ui-priority--header)))))

(ert-deftest harness-ui-priority-set-sends-the-level ()
  "Setting a priority sends it and says what the session's is now."
  (harness-ui-priority-test-with
    (let (sent)
      (harness-ui-priority-test-recording
        (harness-ui-priority-test-session "s1" '(:priority "medium"))
        (should (equal '("Priority: high")
                       (harness-ui-priority-test-messages
                        (lambda () (harness-set-priority "s1" "high")))))
        (should (equal '(("_harness/priority/set" (:sessionId "s1" :priority "high"))) sent))
        (setq sent nil)
        ;; Back to the default.
        (should (equal '("Priority: medium")
                       (harness-ui-priority-test-messages
                        (lambda () (harness-set-priority "s1" "medium")))))
        (should (equal '(("_harness/priority/set" (:sessionId "s1" :priority "medium"))) sent))
        ;; A name no level has changes nothing.
        (setq sent nil)
        (should (equal '("Priority is low, medium or high, not \"urgent\"")
                       (harness-ui-priority-test-messages
                        (lambda () (harness-set-priority "s1" "urgent")))))
        (should-not sent)))))

(ert-deftest harness-ui-priority-set-asks-for-the-level ()
  "Interactively it asks, offering the session's own level as the default."
  (harness-ui-priority-test-with
    (let (sent asked)
      (harness-ui-priority-test-recording
       (cl-letf (((symbol-function 'completing-read)
                  (lambda (prompt collection &optional _predicate _require _initial _hist default)
                    (setq asked (list prompt collection default))
                    "low")))
        (harness-ui-priority-test-session "s1" '(:priority "high"))
        (harness-ui-priority-test-chat "s1"
          (should (equal '("Priority: low")
                         (harness-ui-priority-test-messages
                          (lambda () (call-interactively #'harness-set-priority)))))
          (should (equal "Priority: " (car asked)))
          (should (equal '("low" "medium" "high") (cadr asked)))
          (should (equal "high" (nth 2 asked)))
          (should (equal '(("_harness/priority/set" (:sessionId "s1" :priority "low"))) sent))))))))

(ert-deftest harness-ui-priority-click-sets-the-chat-session ()
  "A click on the segment sets the priority of the session of its chat."
  (harness-ui-priority-test-with
    (let (sent)
      (harness-ui-priority-test-recording
       (cl-letf (((symbol-function 'completing-read)
                  (lambda (_prompt &rest _) "medium")))
        (harness-ui-priority-test-session "s1" '(:priority "high"))
        (harness-ui-priority-test-chat "s1"
          (let* ((seg (harness-ui-priority--header))
                 (click (lookup-key (get-text-property 0 'local-map seg) [mouse-1])))
            (should (equal "priority: high " (substring-no-properties seg)))
            (should (equal '("Priority: medium")
                           (harness-ui-priority-test-messages
                            (lambda ()
                              (funcall click (list 'mouse-1 (list (selected-window) 'header-line '(0 . 0) 0)))))))
            (should (equal '(("_harness/priority/set" (:sessionId "s1" :priority "medium"))) sent)))))))))

(ert-deftest harness-ui-priority-missing-method-says-so ()
  "A harness without the priority module says it is not available."
  (harness-ui-priority-test-with
    (harness-ui-priority-test-session "s1" '(:priority "high"))
    (dolist (err (list '(acp-error -32601 "Method not found: _harness/priority/set" nil)
                       (list 'harness-no-such-method "_harness/priority/set")))
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (_method _params _callback &optional on-error)
                   (funcall on-error err))))
        (should (equal '("Priority is not available (the priority module is not loaded)")
                       (harness-ui-priority-test-messages
                        (lambda () (harness-set-priority "s1" "high")))))))))

(ert-deftest harness-ui-priority-other-failures-are-shown ()
  "Any other failure is shown with its message; a replaced connection is not."
  (harness-ui-priority-test-with
    (harness-ui-priority-test-session "s1" '(:priority "high"))
    (cl-letf (((symbol-function 'harness-ui-call)
               (lambda (_method _params _callback &optional on-error)
                 (funcall on-error '(acp-error -32000 "Session s1 is a sub-agent" nil)))))
      (should (equal '("Harness: setting the priority failed: Session s1 is a sub-agent")
                     (harness-ui-priority-test-messages
                      (lambda () (harness-set-priority "s1" "high"))))))
    (cl-letf (((symbol-function 'harness-ui-call)
               (lambda (_method _params _callback &optional on-error)
                 (funcall on-error '(acp-error -32000 "Session s1 is a sub-agent" nil))))
              ((symbol-function 'harness-ui-connection-replaced-p) (lambda (_err) t)))
      (should-not (harness-ui-priority-test-messages
                   (lambda () (harness-set-priority "s1" "high")))))))

(ert-deftest harness-ui-priority-unknown-session-and-unstarted-task ()
  "A session the harness has not sent, and a task with no session, are said so."
  (harness-ui-priority-test-with
    (let (sent)
      (cl-letf (((symbol-function 'harness-ui-call) (lambda (&rest args) (push args sent))))
        (should (equal '("Priority: the harness has not sent this session yet")
                       (harness-ui-priority-test-messages
                        (lambda () (harness-set-priority "nope" "high")))))
        (with-temp-buffer
          (setq-local harness-ui-setting-target-function
                      (lambda () (cons '(:model "demo:scripted") #'ignore)))
          (should (equal '("Priority applies to a session, not to a task that has not started yet")
                         (harness-ui-priority-test-messages
                          (lambda () (call-interactively #'harness-set-priority))))))
        (should-not sent)))))

(ert-deftest harness-ui-priority-key-and-hook ()
  "The module binds p in the harness keys and adds its header function once.
Shut down, both go again."
  (harness-ui-priority-test-with
    (should (harness-module-ready-p 'ui-priority))
    (should (eq #'harness-set-priority (lookup-key harness-ui-map (kbd "p"))))
    (should (memq #'harness-ui-priority--header harness-chat-header-functions))
    ;; Starting again, as a reload does, adds nothing.
    (harness-ui-priority--init)
    (should (eq #'harness-set-priority (lookup-key harness-ui-map (kbd "p"))))
    (should (= 1 (cl-count #'harness-ui-priority--header harness-chat-header-functions)))
    (harness-ui-priority--shutdown)
    (should-not (lookup-key harness-ui-map (kbd "p")))
    (should-not (memq #'harness-ui-priority--header harness-chat-header-functions))))

(provide 'harness-ui-priority-test)
;;; harness-ui-priority-test.el ends here
