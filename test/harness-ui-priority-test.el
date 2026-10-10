;;; harness-ui-priority-test.el --- Tests for session priority in the UI  -*- lexical-binding: t; -*-
;;; Commentary:

;; The chat header's priority segment for a session at low or high
;; priority and for one at the default (no segment), what it says of a
;; session that inherits its parent's priority; the commands that set,
;; raise and lower a session's priority through
;; `_harness/priority/set', the bulk one through `_harness/priority/set-all',
;; what a target that is not a session says, what setting a priority says
;; when the harness has no priority module or knows no such session, and
;; the module's keys and hooks, added and removed again.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)

(defvar harness-acp-token)
(defvar harness-acp--server-enabled)
(defvar harness-ui--sessions)
(defvar harness-ui-map)
(defvar harness-ui-session-id)
(defvar harness-ui-setting-target-function)
(defvar harness-ui-session-at-point-function)
(defvar harness-chat-header-functions)
(defvar harness-ui-event-functions)

(declare-function harness-set-priority "harness-ui-priority")
(declare-function harness-set-priority-all "harness-ui-priority")
(declare-function harness-priority-raise "harness-ui-priority")
(declare-function harness-priority-lower "harness-ui-priority")
(declare-function harness-priority-shift-session "harness-ui-priority")
(declare-function harness-ui-priority--header "harness-ui-priority")
(declare-function harness-ui-priority--init "harness-ui-priority")
(declare-function harness-ui-priority--shutdown "harness-ui-priority")
(declare-function harness-ui-priority--on-event "harness-ui-priority")
(declare-function harness-ui-priority--target "harness-ui-priority")
(declare-function harness-ui-priority-level-of "harness-ui-priority")

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

(defun harness-ui-priority-test-session (id ext &optional props)
  "Cache session ID, whose :ext plist is EXT, as the UI keeps sessions.
PROPS, when given, go first: a `:parent-id', say."
  (puthash id (append props (list :id id :name "Work" :status "idle" :ext ext))
           harness-ui--sessions))

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

(defvar harness-ui-priority-test--answer 'default
  "What the recording stub answers a priority call with.
`default' means the level the call was sent, as the methods answer; a
test that needs another answer, such as the list of sessions a bulk
change changed, sets it.")

(defmacro harness-ui-priority-test-recording (&rest body)
  "Run BODY with `harness-ui-call' recorded in `sent' and answered at once.
Each `_harness/priority/' call is pushed as (METHOD PARAMS) onto the
`sent' of the test, and its callback is given
`harness-ui-priority-test--answer', or the priority it was sent.  A
`_harness/session/list' call -- the cache fetched again, as the event
follower and the bulk command do -- is answered with the cached
sessions and is not recorded, so `sent' holds what the test is about."
  (declare (indent 0))
  `(let ((harness-ui-priority-test--answer 'default))
     (cl-letf (((symbol-function 'harness-ui-call)
                (lambda (method params callback &optional _on-error)
                  (if (equal method "_harness/session/list")
                      (funcall callback (harness-ui-sessions))
                    (push (list method params) sent)
                    (funcall callback (if (eq harness-ui-priority-test--answer 'default)
                                          (plist-get params :priority)
                                        harness-ui-priority-test--answer))))))
       ,@body)))

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

(ert-deftest harness-ui-priority-inherits-its-parents-level ()
  "A session with none of its own is at its parent's, as the harness serves it.
That is what the commands raise and lower from, so a child of a high
session lowers to medium, not to low."
  (harness-ui-priority-test-with
    (harness-ui-priority-test-session "parent" '(:priority "high"))
    (harness-ui-priority-test-session "child" nil '(:parent-id "parent"))
    (harness-ui-priority-test-session "orphan" nil '(:parent-id "gone"))
    (should (equal "high" (harness-ui-priority-level-of (harness-ui-session "child"))))
    (should (equal "medium" (harness-ui-priority-level-of (harness-ui-session "orphan"))))
    ;; A walk cut off before the parent finds none of its own.
    (should (equal "medium" (harness-ui-priority-level-of (harness-ui-session "child")
                                                          11)))
    (should (equal "high" (harness-ui-priority-level-of (harness-ui-session "parent"))))
    ;; A cycle of parents is cut off.
    (harness-ui-priority-test-session "a" nil '(:parent-id "b"))
    (harness-ui-priority-test-session "b" nil '(:parent-id "a"))
    (should (equal "medium" (harness-ui-priority-level-of (harness-ui-session "a"))))))

(ert-deftest harness-ui-priority-raise-and-lower-shift-the-level ()
  "Each command moves the level one step, and says where it already is."
  (harness-ui-priority-test-with
    (let (sent)
      (harness-ui-priority-test-recording
       (harness-ui-priority-test-session "s1" '(:priority "medium"))
       (harness-ui-priority-test-chat "s1"
         (should (equal '("Priority raised to high")
                        (harness-ui-priority-test-messages
                         (lambda () (call-interactively #'harness-priority-raise)))))
         (should (equal '(("_harness/priority/set" (:sessionId "s1" :priority "high"))) sent))
         (setq sent nil)
         ;; Already high: nothing is sent.
         (harness-ui-priority-test-session "s1" '(:priority "high"))
         (should (equal '("Priority is high already")
                        (harness-ui-priority-test-messages
                         (lambda () (call-interactively #'harness-priority-raise)))))
         (should-not sent)
         (should (equal '("Priority lowered to medium")
                        (harness-ui-priority-test-messages
                         (lambda () (call-interactively #'harness-priority-lower)))))
         (should (equal '(("_harness/priority/set" (:sessionId "s1" :priority "medium"))) sent))
         (setq sent nil)
         (harness-ui-priority-test-session "s1" '(:priority "low"))
         (should (equal '("Priority is low already")
                        (harness-ui-priority-test-messages
                         (lambda () (call-interactively #'harness-priority-lower)))))
         (should-not sent))))
    ;; With a prefix argument they ask for the level instead.
    (let (sent asked)
      (harness-ui-priority-test-recording
       (cl-letf (((symbol-function 'completing-read)
                  (lambda (_prompt &rest _) (setq asked t) "low")))
         (harness-ui-priority-test-session "s1" '(:priority "medium"))
         (harness-ui-priority-test-chat "s1"
           (should (equal '("Priority: low")
                          (harness-ui-priority-test-messages
                           (lambda () (harness-priority-raise '(4))))))
           (should asked)
           (should (equal '(("_harness/priority/set" (:sessionId "s1" :priority "low"))) sent))))))))

(ert-deftest harness-ui-priority-shift-shared-with-the-session-list ()
  "`harness-priority-shift-session' moves a named session's level.
It is what the session list's keys are, so they need no level logic of
their own: an unknown session is said so, and DONE gets the new level."
  (harness-ui-priority-test-with
    (let (sent done)
      (harness-ui-priority-test-recording
       (harness-ui-priority-test-session "s1" '(:priority "low"))
       (should (equal '("Priority is low already")
                      (harness-ui-priority-test-messages
                       (lambda () (harness-priority-shift-session "s1" 3)))))
       (should-not sent)
       (harness-priority-shift-session "s1" 1 (lambda (level) (setq done level)))
       (should (equal '(("_harness/priority/set" (:sessionId "s1" :priority "medium"))) sent))
       (should (equal "medium" done))
       (setq sent nil)
       (should (equal '("Priority: the harness has not sent this session yet")
                      (harness-ui-priority-test-messages
                       (lambda () (harness-priority-shift-session "nope" 1)))))
       (should-not sent)))))

(ert-deftest harness-ui-priority-set-all-sends-the-bulk-request ()
  "Every current session and task of every project changes at once.
The answer's ids are counted, and none of them is said to have been
changed, the bulk method leaving a session at that level alone."
  (harness-ui-priority-test-with
    (let (sent asked)
      (harness-ui-priority-test-recording
       (cl-letf (((symbol-function 'completing-read)
                  (lambda (prompt &rest _) (setq asked prompt) "high")))
         (setq harness-ui-priority-test--answer '("s2" "s1"))
         (should (equal '("Priority → high for 2 sessions")
                        (harness-ui-priority-test-messages
                         (lambda () (call-interactively #'harness-set-priority-all)))))
         (should (equal "Priority for every session and task: " asked))
         (should (equal '(("_harness/priority/set-all"
                           (:priority "high" :filter (:active t :tasks t)))) sent))
         ;; Nothing changed: it says the level they are all at.
         (setq sent nil harness-ui-priority-test--answer nil)
         (should (equal '("Every current session and task is at high already")
                        (harness-ui-priority-test-messages
                         (lambda () (harness-set-priority-all "high")))))
         (should (equal '(("_harness/priority/set-all"
                           (:priority "high" :filter (:active t :tasks t)))) sent))
         ;; A name no level has changes nothing.
         (setq sent nil)
         (should (equal '("Priority is low, medium or high, not \"urgent\"")
                        (harness-ui-priority-test-messages
                         (lambda () (harness-set-priority-all "urgent")))))
         (should-not sent))))))

(ert-deftest harness-ui-priority-follows-the-ext-changed-event ()
  "A priority the harness announces has the session cache fetched again.
The key arrives as \":priority\", or as the keyword a local event carries."
  (harness-ui-priority-test-with
    (let (refreshed)
      (cl-letf (((symbol-function 'harness-ui-refresh-sessions)
                 (lambda (&optional callback) (push t refreshed) (when callback (funcall callback nil)))))
        (harness-ui-priority--on-event "session/ext-changed" '("s1" ":priority" "high"))
        (harness-ui-priority--on-event "session/ext-changed" '("s1" :priority "low"))
        (should (= 2 (length refreshed)))
        ;; Another setting of a session's, or another event, is not ours.
        (harness-ui-priority--on-event "session/ext-changed" '("s1" ":supervisor" t))
        (harness-ui-priority--on-event "session/created" '("s1"))
        (should (= 2 (length refreshed)))))))

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

(ert-deftest harness-ui-priority-unknown-session-and-no-session-target ()
  "A session the harness has not sent, and a target that is no session, are said so.
A task board's next-task settings are the second: a priority is a
session's, so the board's + and - on a card are what sets a task's."
  (harness-ui-priority-test-with
    (let (sent)
      (cl-letf (((symbol-function 'harness-ui-call) (lambda (&rest args) (push args sent))))
        (should (equal '("Priority: the harness has not sent this session yet")
                       (harness-ui-priority-test-messages
                        (lambda () (harness-set-priority "nope" "high")))))
        (with-temp-buffer
          (setq-local harness-ui-setting-target-function
                      (lambda () (cons '(:model "demo:scripted") #'ignore)))
          (should (equal '("Priority is a session's: point at a task or a session (the board's + and - set a task's)")
                         (harness-ui-priority-test-messages
                          (lambda () (call-interactively #'harness-set-priority)))))
          (should (equal '("Priority is a session's: point at a task or a session (the board's + and - set a task's)")
                         (harness-ui-priority-test-messages
                          (lambda () (call-interactively #'harness-priority-raise))))))
        (should-not sent)))))

(ert-deftest harness-ui-priority-sets-the-session-at-point ()
  "On a task board the session at point is a task's, a waiting one's included.
That is what the board sets for a task, so the keys work on a task that
has not started, whose session has held its priority since submission."
  (harness-ui-priority-test-with
    (let (sent)
      (harness-ui-priority-test-recording
       (harness-ui-priority-test-session "t-1" '(:priority "medium"))
       (with-temp-buffer
         (setq-local harness-ui-session-at-point-function (lambda () "t-1"))
         (setq-local harness-ui-setting-target-function
                     (lambda () (cons '(:model "demo:scripted") #'ignore)))
         (should (equal '("Priority raised to high")
                        (harness-ui-priority-test-messages
                         (lambda () (call-interactively #'harness-priority-raise)))))
         (should (equal '(("_harness/priority/set" (:sessionId "t-1" :priority "high"))) sent)))))))

(ert-deftest harness-ui-priority-in-the-menu ()
  "The menu has a Priority column: +, -, y and Y with the harness's labels.
`p', beside them, is still the permission mode."
  (harness-ui-priority-test-with
    (let* ((column (transient-get-suffix 'harness-menu '(0 2)))
           (suffixes (aref column (1- (length column))))
           (plist (lambda (s) (if (keywordp (cadr s)) (cdr s) (car (last s)))))
           (keys (mapcar (lambda (s) (plist-get (funcall plist s) :key)) suffixes))
           (labels (mapcar (lambda (s) (plist-get (funcall plist s) :description)) suffixes)))
      (should (equal "Priority" (plist-get (aref column (- (length column) 2)) :description)))
      (should (equal '("+" "-" "y" "Y") keys))
      (should (equal '("Raise priority" "Lower priority" "Set priority…"
                       "Priority for all sessions…")
                     labels))
      (should (eq #'harness-set-permission-mode
                  (plist-get (funcall plist (transient-get-suffix 'harness-menu '(0 1 4))) :command))))))

(ert-deftest harness-ui-priority-keys-and-hooks ()
  "The module binds +, -, y and Y, and adds its header function once.
It follows `session/ext-changed'; p stays the permission mode.  Shut
down, all of it goes again."
  (harness-ui-priority-test-with
    (should (harness-module-ready-p 'ui-priority))
    (should (eq #'harness-priority-raise (lookup-key harness-ui-map (kbd "+"))))
    (should (eq #'harness-priority-lower (lookup-key harness-ui-map (kbd "-"))))
    (should (eq #'harness-set-priority (lookup-key harness-ui-map (kbd "y"))))
    (should (eq #'harness-set-priority-all (lookup-key harness-ui-map (kbd "Y"))))
    (should (eq #'harness-set-permission-mode (lookup-key harness-ui-map (kbd "p"))))
    (should (memq #'harness-ui-priority--header harness-chat-header-functions))
    (should (memq #'harness-ui-priority--on-event harness-ui-event-functions))
    ;; Starting again, as a reload does, adds nothing.
    (harness-ui-priority--init)
    (should (eq #'harness-set-priority (lookup-key harness-ui-map (kbd "y"))))
    (should (= 1 (cl-count #'harness-ui-priority--header harness-chat-header-functions)))
    (should (= 1 (cl-count #'harness-ui-priority--on-event harness-ui-event-functions)))
    (harness-ui-priority--shutdown)
    (dolist (key '("+" "-" "y" "Y"))
      (should-not (lookup-key harness-ui-map (kbd key))))
    (should (eq #'harness-set-permission-mode (lookup-key harness-ui-map (kbd "p"))))
    (should-not (memq #'harness-ui-priority--header harness-chat-header-functions))
    (should-not (memq #'harness-ui-priority--on-event harness-ui-event-functions))))

(provide 'harness-ui-priority-test)
;;; harness-ui-priority-test.el ends here
