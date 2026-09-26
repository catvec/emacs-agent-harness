;;; harness-session-test.el --- Tests for sessions -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'harness-core)
(require 'harness-session)
(require 'harness-test-helpers)

(harness-module-load 'harness-session)

(defvar harness-session-test--events nil)

(defvar harness-session-test--storage nil)

(defun harness-session-test--setup ()
  "Clear active sessions and point storage at a fresh temporary directory."
  (setq harness-session-test--events nil
        harness-session-test--storage (make-temp-file "harness-sessions-" t))
  (clrhash harness-session--active)
  (clrhash harness-session--project-ids)
  (setq harness-session--by-project nil))

(defmacro harness-session-test--with-storage (&rest body)
  "Run BODY with an isolated session storage directory."
  (declare (indent 0))
  `(let ((harness-session-storage-directory harness-session-test--storage))
     (let ((harness-session-test--capture nil))
       (dolist (event '(session-created session-deleted session-status-changed
                                        session-info-updated session-config-changed
                                        session-entry-added session-usage-changed))
         ;; Drop capture handlers from earlier tests, then install one.
         (puthash event
                  (seq-remove (lambda (handler)
                                (eq (harness-event-handler-module handler)
                                    'harness-session-test))
                              (gethash event harness-core--event-handlers))
                  harness-core--event-handlers)
         (harness-on event
                     (lambda (payload)
                       (push (cons event payload) harness-session-test--events))
                     :module 'harness-session-test))
       ,@body)))

(defun harness-session-test--captured (event)
  "Return captured payloads for EVENT, oldest first."
  (reverse (mapcar #'cdr (seq-filter (lambda (entry) (eq (car entry) event))
                                     harness-session-test--events))))

(defun harness-session-test--make (&optional directory)
  "Create a session in DIRECTORY (a temp dir when omitted)."
  (harness-session-create :cwd (or directory (make-temp-file "harness-project-" t))))

(ert-deftest harness-session-create-and-info ()
  (harness-session-test--setup)
  (harness-session-test--with-storage
    (let* ((directory (make-temp-file "harness-project-" t))
           (session (harness-session-create :cwd directory :title "Test session"))
           (info (harness-session-info session)))
      (should (equal (plist-get info :cwd) (file-name-as-directory directory)))
      (should (equal (plist-get info :title) "Test session"))
      (should (equal (plist-get info :status) "idle"))
      (should (equal (harness-session-permission-mode session) 'ask))
      (should (file-exists-p (harness-session--metadata-file session)))
      (should (= (length (harness-session-test--captured 'session-created)) 1)))))

(ert-deftest harness-session-create-requires-absolute-cwd ()
  (harness-session-test--setup)
  (harness-session-test--with-storage
    (should-error (harness-session-create :cwd "relative/path")
                  :type 'harness-user-error)))

(ert-deftest harness-session-project-root-detection ()
  (harness-session-test--setup)
  (let* ((root (make-temp-file "harness-repo-" t))
         (sub (expand-file-name "packages/app" root)))
    (make-directory (expand-file-name ".git" root) t)
    (make-directory sub t)
    (should (equal (harness-config-project-root sub)
                   (file-name-as-directory root)))
    ;; A directory with no project of its own is its own root.
    (let ((lonely (make-temp-file "harness-lonely-" t)))
      (should (equal (harness-config-project-root lonely)
                     (file-name-as-directory lonely))))))

(ert-deftest harness-session-append-persists-and-reloads ()
  (harness-session-test--setup)
  (harness-session-test--with-storage
    (let* ((session (harness-session-test--make))
           (id (harness-session-id session)))
      (harness-session-append session
                              (list :sessionUpdate "user_message_chunk"
                                    :content (list :type "text" :text "hello")
                                    :messageId "m1"))
      (harness-session-append session
                              (list :sessionUpdate "agent_message_chunk"
                                    :content (list :type "text" :text "hi there")
                                    :messageId "m2"))
      (should (= (length (harness-session-entries session)) 2))
      (harness-session-save session)
      (should (= (harness-session-persisted session) 2))
      ;; Reload from disk with a clean active registry.
      (clrhash harness-session--active)
      (let* ((reloaded (harness-session-load id))
             (entries (harness-test-settle
                       (harness-session-ensure-entries reloaded))))
        (should (equal (length (harness-session-entries reloaded)) 2))
        (should (equal (plist-get (plist-get (aref (harness-session-entries reloaded) 1) :content)
                                  :text)
                       "hi there"))
        (should (plist-get (aref (harness-session-entries reloaded) 0) :id))
        (should (harness-deferred-resolved-p entries))))))

(ert-deftest harness-session-unicode-round-trip ()
  ;; json-serialize returns unibyte UTF-8; writing it into a buffer must not
  ;; leave raw-byte characters behind (which used to trigger a blocking
  ;; coding-system prompt from the save timer).
  (harness-session-test--setup)
  (harness-session-test--with-storage
    (let* ((session (harness-session-test--make))
           (id (harness-session-id session))
           (text "em\u2014dash \u2026 \u65e5\u672c\u8a9e \U0001F389"))
      (harness-session-append session
                              (list :sessionUpdate "agent_message_chunk"
                                    :content (list :type "text" :text text)
                                    :messageId "m1"))
      (harness-session-save session)
      (should (file-exists-p (harness-session--transcript-file session)))
      (with-temp-buffer
        (insert-file-contents (harness-session--transcript-file session))
        (let ((contents (buffer-string)))
          (should (not (cl-loop for character across contents
                                thereis (and (>= character #x3FFF80)
                                             (<= character #x3FFFFF)))))
          (should (equal (plist-get (plist-get (json-parse-string
                                                contents :object-type 'plist)
                                               :content)
                                    :text)
                         text))))
      ;; Reload from disk with a clean active registry.
      (clrhash harness-session--active)
      (let ((reloaded (harness-session-load id)))
        (harness-test-settle (harness-session-ensure-entries reloaded))
        (should (equal (plist-get (plist-get (aref (harness-session-entries reloaded) 0)
                                             :content)
                                  :text)
                       text))
        (should (equal (plist-get (harness-session-info reloaded) :title)
                       (plist-get (harness-session-info session) :title)))))))

(ert-deftest harness-session-entry-events-carry-id-and-meta ()
  (harness-session-test--setup)
  (harness-session-test--with-storage
    (let* ((session (harness-session-test--make))
           (entry (harness-session-append
                   session (list :sessionUpdate "user_message_chunk"
                                 :content (list :type "text" :text "x")))))
      (should (plist-get entry :id))
      (should (plist-get (plist-get entry :_meta) :harness))
      (let ((captured (car (last (harness-session-test--captured 'session-entry-added)))))
        (should (equal (plist-get captured :entry) entry))
        (should (plist-get captured :final))))))

(ert-deftest harness-session-streaming-coalesces-into-one-entry ()
  (harness-session-test--setup)
  (harness-session-test--with-storage
    (let* ((session (harness-session-test--make))
           (key '("m1"))
           (base (list :sessionUpdate "agent_message_chunk" :messageId "m1"
                       :content (list :type "text" :text ""))))
      (harness-session-stream-begin session key base)
      (harness-session-stream-chunk
       session key (list :sessionUpdate "agent_message_chunk" :messageId "m1"
                         :content (list :type "text" :text "Hel")))
      (harness-session-stream-chunk
       session key (list :sessionUpdate "agent_message_chunk" :messageId "m1"
                         :content (list :type "text" :text "lo")))
      (should (= (length (harness-session-entries session)) 0))
      (harness-session-stream-end session key)
      (should (= (length (harness-session-entries session)) 1))
      (let ((entry (aref (harness-session-entries session) 0)))
        (should (equal (plist-get (plist-get entry :content) :text) "Hello")))
      ;; Live chunks carried deltas; the final event carried the whole entry.
      (let ((captured (harness-session-test--captured 'session-entry-added)))
        (should (equal (mapcar (lambda (payload) (plist-get payload :delta))
                               (seq-filter (lambda (payload) (plist-get payload :live)) captured))
                       '(nil "Hel" "lo")))
        (let ((final (seq-find (lambda (payload) (plist-get payload :final)) captured)))
          (should (equal (plist-get (plist-get (plist-get final :entry) :content) :text)
                         "Hello")))))))

(ert-deftest harness-session-streaming-tool-call-merges-updates ()
  (harness-session-test--setup)
  (harness-session-test--with-storage
    (let* ((session (harness-session-test--make))
           (key '("call-1")))
      (harness-session-stream-begin
       session key (list :sessionUpdate "tool_call" :toolCallId "call-1"
                         :title "Reading file" :kind "read" :status "pending"))
      (harness-session-stream-chunk
       session key (list :sessionUpdate "tool_call_update" :toolCallId "call-1"
                         :status "in_progress"))
      (harness-session-stream-chunk
       session key (list :sessionUpdate "tool_call_update" :toolCallId "call-1"
                         :status "completed"
                         :content (vector (list :type "content"
                                                :content (list :type "text" :text "ok")))))
      (let ((entry (harness-session-stream-end session key)))
        (should (equal (plist-get entry :status) "completed"))
        (should (equal (plist-get entry :title) "Reading file"))
        (should (= (length (plist-get entry :content)) 1))))))

(ert-deftest harness-session-status-events ()
  (harness-session-test--setup)
  (harness-session-test--with-storage
    (let ((session (harness-session-test--make)))
      (harness-session-set-status session 'running)
      (harness-session-set-status session 'blocked)
      (harness-session-set-status session 'idle)
      (let ((statuses (mapcar (lambda (payload) (plist-get payload :status))
                              (harness-session-test--captured 'session-status-changed))))
        (should (equal statuses '("running" "blocked" "idle"))))
      (should (eq (harness-session-status session) 'idle))
      (should-error (harness-session-set-status session 'bogus)
                    :type 'harness-user-error))))

(ert-deftest harness-session-unread-tracking ()
  (harness-session-test--setup)
  (harness-session-test--with-storage
    (let ((session (harness-session-test--make)))
      (harness-session-append session
                              (list :sessionUpdate "agent_message_chunk"
                                    :content (list :type "text" :text "a")))
      (should (= (harness-session-unread session) 1))
      (harness-session-append session
                              (list :sessionUpdate "user_message_chunk"
                                    :content (list :type "text" :text "b")))
      (should (= (harness-session-unread session) 0)))))

(ert-deftest harness-session-configuration-and-set-config ()
  (harness-session-test--setup)
  (harness-session-test--with-storage
    (let* ((session (harness-session-test--make))
           (configuration (harness-session-configuration session))
           (options (plist-get configuration :configOptions)))
      (should (vectorp options))
      (should (equal (plist-get (aref options 0) :category) "model"))
      (harness-session-set-config session "model" "gpt-test")
      (should (equal (harness-session-model session) "gpt-test"))
      (harness-session-set-config session "permission" "auto")
      (should (eq (harness-session-permission-mode session) 'auto))
      (harness-session-set-config session "mode" "plan")
      (should (equal (harness-session-mode session) "plan"))
      (let ((changed (harness-session-test--captured 'session-config-changed)))
        (should (= (length changed) 3))
        (should (equal (plist-get (car (last changed)) :config-options)
                       (plist-get (harness-session-configuration session) :configOptions)))))))

(ert-deftest harness-session-usage-and-cost ()
  (harness-session-test--setup)
  (harness-session-test--with-storage
    (let ((session (harness-session-test--make)))
      (harness-session-add-usage session :input 100 :output 20
                                 :cache-read 50 :context-used 170 :context-size 200000)
      (harness-session-add-usage session :input 10 :output 5)
      (harness-session-add-cost session 0.25 "USD")
      (harness-session-add-cost session 0.05)
      (should (equal (harness-session-usage session)
                     '(:input 110 :output 25 :cache-read 50 :cache-write 0)))
      (should (= (harness-session-context-used session) 170))
      (should (= (plist-get (harness-session-cost session) :amount) 0.3))
      (let ((usage-events (harness-session-test--captured 'session-usage-changed)))
        (should (= (length usage-events) 4))
        (should (equal (plist-get (car (last usage-events)) :used) 170))))))

(ert-deftest harness-session-fork-copies-transcript-and-links-parent ()
  (harness-session-test--setup)
  (harness-session-test--with-storage
    (let* ((session (harness-session-create :cwd (make-temp-file "harness-project-" t)
                                            :title "Original"
                                            :model "m1"))
           (first (harness-session-append session (list :sessionUpdate "user_message_chunk"
                                                        :content (list :type "text" :text "one"))))
           (_second (harness-session-append session (list :sessionUpdate "agent_message_chunk"
                                                          :content (list :type "text" :text "two"))))
           (fork (harness-session-fork session :entry-id (plist-get first :id))))
      (should (equal (harness-session-parent-id fork) (harness-session-id session)))
      (should (equal (harness-session-fork-entry-id fork) (plist-get first :id)))
      (should (equal (harness-session-model fork) "m1"))
      (should (= (length (harness-session-entries fork)) 1))
      (should (string-prefix-p "Original" (harness-session-title fork)))
      (should (member (harness-session-id fork)
                      (harness-session-children (harness-session-id session)))))))

(ert-deftest harness-session-list-scopes-and-paginates ()
  (harness-session-test--setup)
  (harness-session-test--with-storage
    (let* ((project-a (make-temp-file "harness-a-" t))
           (project-b (make-temp-file "harness-b-" t))
           (a1 (harness-session-create :cwd project-a :title "a1"))
           (a2 (harness-session-create :cwd project-a :title "a2"))
           (b1 (harness-session-create :cwd project-b :title "b1")))
      ;; Make a2 the most recently updated.
      (harness-session-set-title a2 "a2 updated")
      (let* ((scoped (plist-get (harness-session-list :cwd project-a) :sessions))
             (all (plist-get (harness-session-list) :sessions)))
        (should (= (length scoped) 2))
        (should (equal (plist-get (aref scoped 0) :sessionId) (harness-session-id a2)))
        (should (= (length all) 3))
        (should (member (harness-session-id b1)
                        (mapcar (lambda (info) (plist-get info :sessionId)) (append all nil)))))
      (let* ((first-page (harness-session-list :cwd project-a :limit 1))
             (cursor (plist-get first-page :nextCursor))
             (second-page (harness-session-list :cwd project-a :limit 1 :cursor cursor)))
        (should (= (length (plist-get first-page :sessions)) 1))
        (should cursor)
        (should (= (length (plist-get second-page :sessions)) 1))
        (should-not (plist-get second-page :nextCursor))
        (should-not (equal (plist-get (aref (plist-get first-page :sessions) 0) :sessionId)
                           (plist-get (aref (plist-get second-page :sessions) 0) :sessionId)))))))

(ert-deftest harness-session-delete-removes-files ()
  (harness-session-test--setup)
  (harness-session-test--with-storage
    (let* ((session (harness-session-test--make))
           (directory (file-name-directory (harness-session--metadata-file session))))
      (should (file-directory-p directory))
      (harness-session-delete session)
      (should-not (file-directory-p directory))
      (should-not (harness-session-active (harness-session-id session)))
      (should (= (length (harness-session-test--captured 'session-deleted)) 1)))))

(ert-deftest harness-session-service-surface ()
  (harness-session-test--setup)
  (harness-session-test--with-storage
    (let* ((directory (make-temp-file "harness-project-" t))
           (created (harness-service-call "session" 'create :cwd directory :title "svc"))
           (id (plist-get created :sessionId)))
      (should id)
      (should (equal (plist-get (harness-service-call "session" 'load :session-id id) :title)
                     "svc"))
      (harness-service-call "session" 'append
                            :session-id id
                            :entry (list :sessionUpdate "user_message_chunk"
                                         :content (list :type "text" :text "svc message")))
      (let ((entries (harness-service-call "session" 'entries :session-id id)))
        (when (harness-deferred-p entries)
          (harness-test-settle entries)
          (setq entries (harness-deferred-value entries)))
        (should (= (length entries) 1)))
      (harness-service-call "session" 'rename :session-id id :title "renamed")
      (should (equal (plist-get (harness-service-call "session" 'info :session-id id) :title)
                     "renamed"))
      (harness-service-call "session" 'set-status :session-id id :status "running")
      (should (eq (harness-session-status (harness-session-active id)) 'running))
      (harness-service-call "session" 'close :session-id id)
      (should-not (harness-session-active id))
      (should (plist-get (harness-service-call "session" 'load :session-id id) :sessionId))
      ;; Unknown session is a user error, which ACP maps to invalid params.
      (should-error (harness-service-call "session" 'info :session-id "nope")
                    :type 'harness-session-not-found))))

(ert-deftest harness-session-save-flushes-pending-batch ()
  (harness-session-test--setup)
  (harness-session-test--with-storage
    (let* ((session (harness-session-test--make))
           (id (harness-session-id session)))
      (harness-session-set-title session "batched")
      ;; The title change is batched; a fresh read only sees it after save.
      (harness-session-save session)
      (let ((metadata (harness-session--read-metadata (harness-session--metadata-file session))))
        (should (equal (plist-get metadata :title) "batched")))
      (should (harness-session-active id)))))

(ert-deftest harness-session-state-round-trip ()
  (harness-session-test--setup)
  (harness-session-test--with-storage
    (let* ((session (harness-session-test--make))
           (id (harness-session-id session)))
      (harness-session-state-set session 'todos (vector (list :id "t1" :text "first")))
      (harness-session-state-set session 'plan "step one")
      (should (equal (harness-session-state-get session 'plan) "step one"))
      (harness-session-save session)
      (clrhash harness-session--active)
      (let ((reloaded (harness-session-load id)))
        (should (equal (harness-session-state-get reloaded 'plan) "step one"))
        (should (equal (aref (harness-session-state-get reloaded 'todos) 0)
                       '(:id "t1" :text "first")))
        (harness-session-state-delete reloaded 'plan)
        (should-not (harness-session-state-get reloaded 'plan))))))

(ert-deftest harness-session-state-keys-normalize ()
  ;; Keyword and symbol keys address the same slot, and the projected
  ;; plist uses a single-colon keyword.
  (harness-session-test--setup)
  (harness-session-test--with-storage
    (let ((session (harness-session-test--make)))
      (harness-session-state-set session :last-turn-at 12.5)
      (should (equal (harness-session-state-get session 'last-turn-at) 12.5))
      (should (equal (harness-session-state-get session :last-turn-at) 12.5))
      (let ((projected (harness-session--state-plist session)))
        (should (equal (plist-get projected :last-turn-at) 12.5))
        (should-not (plist-get projected ::last-turn-at)))
      (harness-session-state-delete session :last-turn-at)
      (should-not (harness-session-state-get session 'last-turn-at)))))

(provide 'harness-session-test)
;;; harness-session-test.el ends here
