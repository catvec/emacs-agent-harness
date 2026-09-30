;;; harness-ui-chat-test.el --- Tests for the chat interface -*- lexical-binding: t; -*-

;;; Commentary:

;; Rendering, composing, queueing, attachments and the configuration
;; controls are tested against stubbed ACP requests; the last test drives
;; the real harness stack end to end through the local UI connection.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness)
(require 'harness-core)
(require 'harness-session)
(require 'harness-tools)
(require 'harness-agent)
(require 'harness-ui)
(require 'harness-ui-chat)
(require 'harness-ui-sessions)
(require 'harness-ui-config)
(require 'harness-ui-notifier)
(require 'harness-ui-tree)
(require 'harness-test-helpers)

(harness-module-load 'harness-ui)
(harness-module-load 'harness-ui-chat)
(harness-module-load 'harness-ui-sessions)
(harness-module-load 'harness-ui-config)

(defvar harness-ui-chat-test--sent nil
  "Blocks captured from `harness-ui-send'.")

(defvar harness-ui-chat-test--requests nil
  "Requests captured from `harness-ui-request'.")

(defmacro harness-ui-chat-test--with-stubs (&rest body)
  "Run BODY with ACP calls stubbed out."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'harness-ui-send)
              (lambda (_session-id blocks)
                (setq harness-ui-chat-test--sent
                      (append harness-ui-chat-test--sent (list blocks)))
                (let ((deferred (harness-deferred-new)))
                  (harness-deferred-resolve deferred (list :stopReason "end_turn"))
                  deferred)))
             ((symbol-function 'harness-ui-request)
              (lambda (method &optional params)
                (setq harness-ui-chat-test--requests
                      (append harness-ui-chat-test--requests
                              (list (cons method params))))
                (let ((deferred (harness-deferred-new)))
                  (harness-deferred-resolve
                   deferred
                   (pcase method
                     ("session/load" (make-hash-table))
                     ("_harness/session/info" (list :sessionId "s1" :title "Test"
                                                    :model "mock/m1" :status "idle"))
                     ("session/list" (list :sessions []))
                     ("_harness/skills/load"
                      (list :name (plist-get params :name) :content "SKILL BODY"))
                     (_ (make-hash-table))))
                  deferred))))
     (let ((harness-ui-chat-test--sent nil)
           (harness-ui-chat-test--requests nil))
       ,@body)))

(defun harness-ui-chat-test--find-face (face &optional buffer)
  "Return non-nil when FACE appears in BUFFER's text."
  (with-current-buffer (or buffer (current-buffer))
    (save-excursion
      (goto-char (point-min))
      (let ((found nil))
        (while (and (not found) (not (eobp)))
          (let ((value (get-text-property (point) 'face)))
            (when (or (eq value face)
                      (and (listp value) (memq face value)))
              (setq found t)))
          (forward-char 1))
        found))))

(defun harness-ui-chat-test--buffer (&optional session-id)
  "Create and return a fresh chat buffer for SESSION-ID."
  (let* ((id (or session-id "s1"))
         (old (gethash id harness-ui-chat--buffers)))
    (when (buffer-live-p old)
      (kill-buffer old))
    (remhash id harness-ui-chat--buffers)
    (remhash id harness-ui-chat--pending-updates)
    (let ((buffer (harness-ui-chat--buffer id)))
    (with-current-buffer buffer
      (setq harness-ui-chat--info (list :sessionId (or session-id "s1")
                                        :title "Test" :model "mock/m1" :cwd "/tmp")
            harness-ui-chat--status 'idle)
      (harness-ui-chat--refresh-header))
    buffer)))

(defun harness-ui-chat-test--apply (buffer update)
  "Apply UPDATE to BUFFER and lay the transcript out."
  (harness-ui-chat--apply-update buffer "s1" update)
  (with-current-buffer buffer
    (when harness-ui-chat--needs-rebuild
      (harness-ui-chat-rebuild))))

(defun harness-ui-chat-test--text (&optional buffer)
  "Return the buffer text without properties."
  (with-current-buffer (or buffer (current-buffer))
    (buffer-substring-no-properties (point-min) (point-max))))

;;; Rendering

(ert-deftest harness-ui-chat-renders-user-and-agent-messages ()
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (harness-ui-chat-test--apply buffer
                                   (list :sessionUpdate "user_message_chunk"
                                         :messageId "u1" :final t
                                         :content (list :type "text" :text "hello agent")))
      (harness-ui-chat-test--apply buffer
                                   (list :sessionUpdate "agent_message_chunk"
                                         :messageId "a1" :final t
                                         :content (list :type "text" :text "hello human")))
      (let ((text (harness-ui-chat-test--text buffer)))
        (should (string-match-p "hello agent" text))
        (should (string-match-p "hello human" text))
        (should (= (length (split-string text "hello agent")) 2)))
      ;; The user message carries the user face.
      (with-current-buffer buffer
        (should (harness-ui-chat-test--find-face 'harness-ui-user-face buffer)))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-streams-deltas-into-one-message ()
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (harness-ui-chat-test--apply buffer
                                   (list :sessionUpdate "agent_message_chunk"
                                         :messageId "a1" :live t :delta "Hel"
                                         :content (list :type "text" :text "Hel")))
      (harness-ui-chat-test--apply buffer
                                   (list :sessionUpdate "agent_message_chunk"
                                         :messageId "a1" :live t :delta "lo"))
      (harness-ui-chat-test--apply buffer
                                   (list :sessionUpdate "agent_message_chunk"
                                         :messageId "a1" :final t
                                         :content (list :type "text" :text "Hello")))
      (let ((text (harness-ui-chat-test--text buffer)))
        (should (string-match-p "Hello" text))
        (should (= (length (split-string text "Hello")) 2))))
    (kill-buffer "*harness: s1*")))

(ert-deftest harness-ui-chat-collapses-thinking-and-tools ()
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (harness-ui-chat-test--apply buffer
                                   (list :sessionUpdate "agent_thought_chunk"
                                         :messageId "t1" :final t
                                         :content (list :type "text"
                                                        :text "Checking the plan\nsecret reasoning")))
      (harness-ui-chat-test--apply buffer
                                   (list :sessionUpdate "tool_call" :toolCallId "c1"
                                         :name "bash" :status "completed" :final t
                                         :content (vector (list :type "content"
                                                                :content (list :type "text"
                                                                               :text "tool output")))))
      (let ((text (harness-ui-chat-test--text buffer)))
        (should (string-match-p "Thinking" text))
        ;; Collapsed, the first line previews as a hint; the rest is hidden.
        (should (string-match-p "Checking the plan" text))
        (should-not (string-match-p "secret reasoning" text))
        (should (string-match-p "bash" text))
        (should-not (string-match-p "tool output" text)))
      ;; Un-collapse the thinking block by clicking its button.
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "Thinking")
        (push-button (match-beginning 0)))
      (should (string-match-p "secret reasoning" (harness-ui-chat-test--text buffer)))
      (should (= (length (split-string (harness-ui-chat-test--text buffer)
                                       "secret reasoning"))
                 2))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-coalesces-allow-listed-tools ()
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (dolist (index (list 1 2))
        (harness-ui-chat-test--apply
         buffer
         (list :sessionUpdate "tool_call" :toolCallId (format "c%d" index)
               :name "read" :status "completed" :final t
               :content (vector (list :type "content"
                                      :content (list :type "text" :text "file body"))))))
      (let ((text (harness-ui-chat-test--text buffer)))
        (should (string-match-p "tools read ×2" text))
        (should-not (string-match-p "file body" text)))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-composer-is-typeable ()
  ;; `special-mode-map' remaps self-insert to undefined and binds `q',
  ;; `SPC' and friends; the composer must not inherit those.
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (with-current-buffer buffer
        (should (eq (key-binding (kbd "i")) #'harness-ui-chat--self-insert))
        (should (eq (key-binding (kbd "SPC")) #'harness-ui-chat--self-insert))
        (should (eq (key-binding (kbd "q")) #'harness-ui-chat-quit))
        (should (eq (command-remapping #'self-insert-command)
                    #'harness-ui-chat--self-insert)))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-open-puts-point-in-the-composer ()
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (with-current-buffer buffer
        (harness-ui-chat--display-full buffer)
        (should (= (point) (harness-ui-chat--compose-end-point))))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-renders-hints-and-errors ()
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (harness-ui-chat-test--apply buffer
                                   (list :sessionUpdate "_harness/system_hint"
                                         :final t
                                         :content (list :type "text" :text "model changed")
                                         :level "info"))
      (should (string-match-p "model changed" (harness-ui-chat-test--text buffer)))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-retires-a-transient-hint ()
  ;; A hint with an id is replaced when the same id arrives with no text;
  ;; the ACP projection carries the id in _meta.
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer))
          (hint (lambda (text)
                  (list :sessionUpdate "_harness/system_hint"
                        :final t
                        :_meta (list :harness (list :entryId "auto-name"))
                        :content (list :type "text" :text text)
                        :level "info"))))
      (harness-ui-chat-test--apply buffer (funcall hint "Naming this conversation…"))
      (should (string-match-p "Naming this conversation"
                              (harness-ui-chat-test--text buffer)))
      (harness-ui-chat-test--apply buffer (funcall hint ""))
      (should-not (string-match-p "Naming this conversation"
                                  (harness-ui-chat-test--text buffer)))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-renders-plans-with-markdown ()
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (harness-ui-chat-test--apply buffer
                                   (list :sessionUpdate "plan"
                                         :id "plan-1" :title "Fix the bug"
                                         :final t
                                         :content (list :type "text"
                                                        :text "# Approach\n\n- read the code\n- patch it")))
      (let ((text (harness-ui-chat-test--text buffer)))
        (should (string-match-p "Fix the bug" text))
        (should (string-match-p "Approach" text))
        (should (string-match-p "read the code" text))
        ;; The heading marker is concealed with a display property while
        ;; the text stays in the buffer (searchable, exportable).
        (with-current-buffer buffer
          (goto-char (point-min))
          (search-forward "# Approach")
          (should (equal (get-text-property (match-beginning 0) 'display) ""))))
      (with-current-buffer buffer
        (should (harness-ui-chat-test--find-face 'harness-ui-h1-face buffer)))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-btw-forks-and-asks ()
  (harness-ui-chat-test--with-stubs
    (let* ((buffer (harness-ui-chat-test--buffer))
           (captured (list (cons :fork-requests nil)
                           (cons :opened nil)
                           (cons :sent nil))))
      (with-current-buffer buffer
        (setq harness-ui-chat--info '(:title "Main session" :sessionId "s1")))
      (cl-letf (((symbol-function 'harness-ui-request)
                 (lambda (method &optional params)
                   (setcdr (assq :fork-requests captured)
                           (cons (cons method params)
                                 (cdr (assq :fork-requests captured))))
                   (let ((deferred (harness-deferred-new)))
                     (harness-deferred-resolve
                      deferred
                      (pcase method
                        ("_harness/session/fork" (list :sessionId "btw-1"))
                        (_ (make-hash-table))))
                     deferred)))
                ((symbol-function 'harness-ui-send)
                 (lambda (_session-id blocks)
                   (setcdr (assq :sent captured)
                           (cons blocks (cdr (assq :sent captured))))
                   (let ((deferred (harness-deferred-new)))
                     (harness-deferred-resolve deferred (list :stopReason "end_turn"))
                     deferred)))
                ((symbol-function 'harness-ui-chat-open)
                 (lambda (session-id &optional position)
                   (setcdr (assq :opened captured)
                           (cons (list session-id position)
                                 (cdr (assq :opened captured))))
                   (harness-ui-chat--buffer session-id))))
        (with-current-buffer buffer
          (harness-ui-chat-btw "what is the cache key?")))
      ;; The fork carries the parent's title with a btw marker.
      (let ((fork (assoc "_harness/session/fork" (cdr (assq :fork-requests captured)))))
        (should fork)
        (should (equal (plist-get (cdr fork) :sessionId) "s1"))
        (should (string-match-p "(btw)" (plist-get (cdr fork) :title))))
      ;; The side conversation was opened and asked.
      (should (equal (car (cdr (assq :opened captured))) '("btw-1" right)))
      (let ((sent (cdr (assq :sent captured))))
        (should (= (length sent) 1))
        (should (equal (plist-get (aref (car sent) 0) :text)
                       "what is the cache key?")))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-fontifies-markdown ()
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (harness-ui-chat-test--apply buffer
                                   (list :sessionUpdate "agent_message_chunk"
                                         :messageId "a1" :final t
                                         :content (list :type "text"
                                                        :text "# Title\n\nsome `code` here")))
      (should (harness-ui-chat-test--find-face 'harness-ui-h1-face buffer))
      (should (harness-ui-chat-test--find-face 'harness-ui-code-face buffer))
      (kill-buffer buffer))))

;;; Composing

(ert-deftest harness-ui-chat-sends-and-clears ()
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (with-current-buffer buffer
        (goto-char (harness-ui-chat--compose-point))
        (insert "make it so")
        (harness-ui-chat-send)
        (should (equal (harness-ui-chat--compose-text) "")))
      (should (= (length harness-ui-chat-test--sent) 1))
      (let ((blocks (car harness-ui-chat-test--sent)))
        (should (equal (plist-get (aref blocks 0) :text) "make it so")))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-composer-chrome-is-read-only ()
  "The prompt, buttons and queued list are protected; the draft is not."
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (with-current-buffer buffer
        ;; The draft accepts typed text, even while empty.
        (goto-char (harness-ui-chat--compose-point))
        (insert "draft")
        (should (equal (harness-ui-chat--compose-text) "draft"))
        ;; The prompt is read-only.
        (goto-char (point-min))
        (search-forward "❯")
        (should-error (delete-region (match-beginning 0) (match-end 0))
                      :type 'text-read-only)
        ;; So is the button row: neither deletion nor insertion works.
        (goto-char (point-min))
        (search-forward "Send")
        (let ((start (match-beginning 0))
              (end (match-end 0)))
          (should-error (delete-region start end) :type 'text-read-only)
          (goto-char end)
          (should-error (insert "!") :type 'text-read-only))
        ;; Point parked after the buttons still types into the draft.
        (goto-char (point-max))
        (harness-ui-chat--enter-composer)
        (insert "!")
        (should (equal (harness-ui-chat--compose-text) "draft!"))
        ;; A queued line is chrome too.
        (setq harness-ui-chat--queue (list (cons nil "later")))
        (harness-ui-chat--render-composer)
        (goto-char (point-min))
        (search-forward "Queued (1)")
        (should-error (delete-region (match-beginning 0) (match-end 0))
                      :type 'text-read-only)
        ;; Clicking a queued item pulls it back into the draft.
        (search-forward "[0]")
        (button-activate (button-at (1- (point)))))
      (with-current-buffer buffer
        (should-not harness-ui-chat--queue)
        (should (equal (harness-ui-chat--compose-text) "later")))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-attach-button-uses-interactive-spec ()
  "Clicking Attach runs the command through `call-interactively'."
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer))
          (file 'unset))
      (cl-letf (((symbol-function 'harness-ui-chat-attach-file)
                 (lambda (arg)
                   (interactive (list "from-spec"))
                   (setq file arg))))
        (with-current-buffer buffer
          (goto-char (point-min))
          (search-forward "Attach")
          (button-activate (button-at (1- (point))))))
      (should (equal file "from-spec"))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-send-steers-a-running-turn ()
  "Mid-turn Send steers the turn instead of queueing for the next one."
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer))
          (steered nil)
          (steer-session nil))
      (with-current-buffer buffer
        (setq harness-ui-chat--status 'running)
        (harness-ui-chat--render-composer)
        (goto-char (harness-ui-chat--compose-point))
        (insert "go left"))
      (cl-letf (((symbol-function 'harness-ui-steer)
                 (lambda (session-id blocks)
                   (setq steer-session session-id
                         steered blocks)
                   (harness-test-resolved nil))))
        (with-current-buffer buffer
          (harness-ui-chat-send)))
      (should (equal steer-session "s1"))
      (should (equal (plist-get (aref steered 0) :text) "go left"))
      ;; Steering is not queueing: the queued list stays empty.
      (should-not harness-ui-chat--queue)
      (should (equal (harness-ui-chat--compose-text) ""))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-running-buttons-stay-send-and-queue ()
  "The button row keeps stable Send and Queue labels while running."
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (with-current-buffer buffer
        (setq harness-ui-chat--status 'running)
        (harness-ui-chat--render-composer)
        (goto-char (point-min))
        (search-forward "Send")
        (should (button-at (1- (point))))
        (goto-char (point-min))
        (search-forward "Queue")
        (should (button-at (1- (point))))
        (should (= (how-many "Queue" (point-min) (point-max)) 1)))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-help-composes-or-describes ()
  "`?' types in the composer and opens help from the transcript."
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (goto-char (harness-ui-chat--compose-point))
              (let ((last-command-event ??))
                (harness-ui-chat-help))
              (should (equal (harness-ui-chat--compose-text) "?"))
              (goto-char (point-min))
              (harness-ui-chat-help)
              (should (get-buffer "*Harness Help*")))
        (when (get-buffer "*Harness Help*")
          (kill-buffer "*Harness Help*"))
        (kill-buffer buffer))))))

(ert-deftest harness-ui-chat-attachments-become-resource-links ()
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer))
          (file (make-temp-file "harness-chat-attach-" nil ".txt")))
      (unwind-protect
          (progn
            (with-temp-file file (insert "payload"))
            (with-current-buffer buffer
              (harness-ui-chat-attach-file file)
              (goto-char (harness-ui-chat--compose-point))
              (insert "look at this")
              (harness-ui-chat-send))
            (let* ((blocks (car harness-ui-chat-test--sent))
                   (link (seq-find (lambda (block)
                                     (equal (plist-get block :type) "resource_link"))
                                   (append blocks nil))))
              (should link)
              (should (equal (plist-get link :uri) (concat "file://" file)))
              (should (= (plist-get link :size) 7))))
        (delete-file file)
        (kill-buffer buffer)))))

(ert-deftest harness-ui-chat-inlines-image-attachments ()
  (harness-ui-chat-test--with-stubs
    (let* ((directory (make-temp-file "harness-chat-img-" t))
           (image (expand-file-name "shot.png" directory))
           (textual (expand-file-name "notes.txt" directory))
           (buffer (harness-ui-chat-test--buffer)))
      ;; A one-pixel PNG stands in for the real thing.
      (with-temp-file image
        (set-buffer-multibyte nil)
        (insert (base64-decode-string
                 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")))
      (with-temp-file textual (insert "notes"))
      (with-current-buffer buffer
        (setq harness-ui-chat--attachments (list (harness-ui-chat--file-attachment image)
                                                 (harness-ui-chat--file-attachment textual)))
        (let* ((blocks (append (harness-ui-chat--message-blocks "look") nil))
               (image-block (seq-find (lambda (block) (equal (plist-get block :type) "image"))
                                      blocks))
               (link-block (seq-find (lambda (block) (equal (plist-get block :type) "resource_link"))
                                     blocks)))
          (should image-block)
          (should (equal (plist-get image-block :mime-type) "image/png"))
          (should (stringp (plist-get image-block :data)))
          (should (> (length (plist-get image-block :data)) 10))
          (should link-block)
          (should (string-match-p "notes\.txt" (plist-get link-block :uri)))))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-oversized-images-stay-links ()
  (harness-ui-chat-test--with-stubs
    (let* ((directory (make-temp-file "harness-chat-big-" t))
           (image (expand-file-name "big.png" directory))
           (buffer (harness-ui-chat-test--buffer)))
      (with-temp-file image (insert (make-string 2000 ?x)))
      (with-current-buffer buffer
        (let ((harness-ui-chat-inline-attachment-bytes 100))
          (setq harness-ui-chat--attachments (list (harness-ui-chat--file-attachment image)))
          (let* ((blocks (append (harness-ui-chat--message-blocks "look") nil))
                 (block (cadr blocks)))
            (should (equal (plist-get block :type) "resource_link")))))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-in-memory-attachments ()
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (with-current-buffer buffer
        (setq harness-ui-chat--attachments
              (list (harness-ui-chat--data-attachment "aGVsbG8=" "image/png" "paste.png")))
        ;; The label announces the kind, and the block inlines the data.
        (should (equal (harness-ui-chat--attachment-kind
                        (car harness-ui-chat--attachments))
                       'image))
        (should (string-match-p "\[image\]"
                                (harness-ui-chat--attachment-label
                                 (car harness-ui-chat--attachments))))
        (let ((block (cadr (append (harness-ui-chat--message-blocks "see") nil))))
          (should (equal (plist-get block :type) "image"))
          (should (equal (plist-get block :mime-type) "image/png"))
          (should (equal (plist-get block :data) "aGVsbG8=")))
        ;; The attachment line renders a button for it.
        (harness-ui-chat--render-composer)
        (goto-char (point-min))
        (should (search-forward "[image] paste.png" nil t)))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-renders-audio-and-video-blocks ()
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (harness-ui-chat-test--apply
       buffer
       (list :sessionUpdate "agent_message_chunk" :messageId "m1" :final t
             :content (vector (list :type "text" :text "here you go")
                              (list :type "audio" :mime-type "audio/wav" :data "UklGRg==")
                              (list :type "video" :mime-type "video/mp4"
                                    :data "AAAA" :name "clip.mp4"))))
      (let ((text (harness-ui-chat-test--text buffer)))
        (should (string-match-p "\[play audio\]" text))
        (should (string-match-p "\[video: clip\.mp4\]" text)))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-queue-while-running ()
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (with-current-buffer buffer
        (setq harness-ui-chat--status 'running)
        (goto-char (harness-ui-chat--compose-point))
        (insert "second thought")
        (harness-ui-chat-queue)
        (should (= (length harness-ui-chat--queue) 1))
        (should-not harness-ui-chat-test--sent)
        (should (string-match-p "Queued (1)" (harness-ui-chat-test--text buffer)))
        ;; Turning idle flushes the queue.
        (harness-ui-chat--on-status (list :status (list :sessionId "s1" :status "idle")))
        (should-not harness-ui-chat--queue))
      (should (= (length harness-ui-chat-test--sent) 1))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-at-file-completion ()
  (harness-ui-chat-test--with-stubs
    (let* ((dir (make-temp-file "harness-chat-comp-" t))
           (buffer nil))
      (unwind-protect
          (progn
            (with-temp-file (expand-file-name "alpha.txt" dir) (insert "x"))
            (setq buffer (harness-ui-chat-test--buffer))
            (with-current-buffer buffer
              (setq harness-ui-chat--info (list :sessionId "s1" :cwd dir))
              (goto-char (harness-ui-chat--compose-point))
              (insert "@")
              (let ((capf (harness-ui-chat-completion-at-point)))
                (should capf)
                (let ((candidates (nth 2 capf)))
                  (should (member "alpha.txt" candidates))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (delete-directory dir t)))))

(ert-deftest harness-ui-chat-header-shows-session-state ()
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (with-current-buffer buffer
        (let ((rendered (prin1-to-string header-line-format)))
          (should (string-match-p "Test" rendered))
          (should (string-match-p "mock/m1" rendered))))
      (kill-buffer buffer))))

(ert-deftest harness-ui-chat-refresh-rerenders ()
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (harness-ui-chat-test--apply buffer
                                   (list :sessionUpdate "agent_message_chunk"
                                         :messageId "a1" :final t
                                         :content (list :type "text" :text "kept")))
      (with-current-buffer buffer
        (harness-ui-chat-refresh-all)
        (should (string-match-p "kept" (harness-ui-chat-test--text buffer))))
      (kill-buffer buffer))))


;;; Stubs shared by the remaining tests

(defun harness-ui-chat-test--stub-method (method params)
  "Default handler for stubbed ACP METHOD with PARAMS."
  (pcase method
    ("session/load" (make-hash-table))
    ("_harness/session/info" (list :sessionId "s1" :title "Test"
                                   :model "mock/m1" :status "idle"))
    ("session/list" (list :sessions []))
    ("session/delete" (make-hash-table))
    ("_harness/session/rename" (make-hash-table))
    ("_harness/session/fork" (list :sessionId "forked"))
    ("_harness/agent/configuration"
     (list :configOptions
           (vector (list :id "model" :name "Model" :type "select"
                         :currentValue "m1"
                         :options (vector (list :value "m1" :name "M1")
                                          (list :value "m2" :name "M2"))))))
    ("session/set_config_option" (make-hash-table))
    (_ (make-hash-table))))

(defun harness-ui-chat-test--resolved (value)
  "Return a resolved deferred of VALUE."
  (let ((deferred (harness-deferred-new)))
    (harness-deferred-resolve deferred value)
    deferred))

(defun harness-ui-chat-test--stub-requests (table)
  "Install request stubs from TABLE, an alist of method -> function.
Methods without an entry use `harness-ui-chat-test--stub-method'."
  (cl-letf (((symbol-function 'harness-ui-request)
             (lambda (method &optional params)
               (let ((handler (cdr (assoc method table))))
                 (harness-ui-chat-test--resolved
                  (if handler
                      (funcall handler params)
                    (harness-ui-chat-test--stub-method method params)))))))
    (funcall (or (cdr (assoc :body table)) #'ignore))))

;;; Session list

(defun harness-ui-chat-test--session-list ()
  "A canned session/list result with a parent and child."
  (list :sessions
        (vector (list :sessionId "root" :cwd "/tmp" :title "Root"
                      :updatedAt "now"
                      :_meta (list :harness (list :status "idle" :model "m1")))
                (list :sessionId "child" :cwd "/tmp" :title "Child"
                      :updatedAt "now"
                      :_meta (list :harness (list :status "running" :model "m1"
                                                  :parentId "root"))))))

(ert-deftest harness-ui-sessions-list-renders-tree ()
  (harness-ui-chat-test--stub-requests
   (list (cons "session/list"
               (lambda (_params) (harness-ui-chat-test--session-list)))
         (cons :body
               (lambda ()
                 (let ((buffer (harness-ui-sessions 'all)))
                   (harness-test-wait-for
                    (lambda () (with-current-buffer buffer tabulated-list-entries)) 5)
                   (with-current-buffer buffer
                     (should (= (length tabulated-list-entries) 2))
                     (should (equal (car (car tabulated-list-entries)) "root"))
                     (should (equal (car (cadr tabulated-list-entries)) "child")))
                   (kill-buffer buffer)))))))

(ert-deftest harness-ui-sessions-toggle-scope ()
  (let ((asked nil))
    (harness-ui-chat-test--stub-requests
     (list (cons "session/list"
                 (lambda (params) (setq asked params) (harness-ui-chat-test--session-list)))
           (cons :body
                 (lambda ()
                   (setq harness-ui-sessions-scope 'project)
                   (let ((buffer (harness-ui-sessions)))
                     (harness-test-wait-for (lambda () asked) 5)
                     (kill-buffer buffer))
                   (should (equal (plist-get asked :mcpServers) []))))))))

(ert-deftest harness-ui-sessions-fork-and-delete ()
  (let ((forked nil) (deleted nil))
    (harness-ui-chat-test--stub-requests
     (list (cons "_harness/session/fork" (lambda (_params) (setq forked t) (list :sessionId "f")))
           (cons "session/delete" (lambda (_params) (setq deleted t) (make-hash-table)))
           (cons "session/list" (lambda (_params) (harness-ui-chat-test--session-list)))
           (cons :body
                 (lambda ()
                   (let ((buffer (harness-ui-sessions 'all)))
                     (harness-test-wait-for
                      (lambda () (with-current-buffer buffer tabulated-list-entries)) 5)
                     (with-current-buffer buffer
                       (goto-char (point-min))
                       (harness-ui-sessions-fork)
                       (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
                         (harness-ui-sessions-delete)))
                     (should forked)
                     (should deleted)
                     (kill-buffer buffer))))))))

;;; Config controls

(ert-deftest harness-ui-config-sets-model ()
  (let ((harness-ui-current-session "s1")
        (set-params nil))
    (cl-letf (((symbol-function 'harness-ui-request)
               (lambda (method &optional params)
                 (when (equal method "session/set_config_option")
                   (setq set-params params))
                 (harness-ui-chat-test--resolved
                  (harness-ui-chat-test--stub-method method params))))
              ((symbol-function 'completing-read)
               (lambda (&rest _args) "M2")))
      (harness-ui-switch-model)
      (harness-test-wait-for (lambda () set-params) 5)
      (should (equal (plist-get set-params :configId) "model"))
      (should (equal (plist-get set-params :value) "m2")))))

(ert-deftest harness-ui-config-requires-a-session ()
  (let ((harness-ui-current-session nil))
    (should-error (harness-ui-switch-model) :type 'user-error)))

(ert-deftest harness-ui-config-choose-labels-values ()
  "The selector completes on value names, not on plist keys."
  (let ((captured nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt collection &rest _args)
                 (setq captured
                       (list :prompt prompt
                             :candidates (funcall collection "" nil t)
                             :metadata (funcall collection "" nil 'metadata)
                             :default (nth 4 _args)))
                 "High")))
      (let ((choice (harness-ui-config--choose
                     '(:id "thinking" :name "Thinking" :currentValue "medium"
                       :options [(:value "low" :name "Low" :description "faster")
                                 (:value "medium" :name "Medium" :description "normal")
                                 (:value "high" :name "High" :description "deeper")]))))
        (should (equal (plist-get choice :value) "high"))
        (should (equal (plist-get captured :prompt) "Thinking: "))
        (should (equal (plist-get captured :candidates) '("Low" "Medium" "High")))
        (should (equal (plist-get captured :default) "Medium"))
        (let ((metadata (plist-get captured :metadata)))
          (should (eq (cdr (assq 'category (cdr metadata))) 'harness-config-value))
          (let ((annotate (cdr (assq 'annotation-function (cdr metadata)))))
            (should (equal (substring-no-properties (funcall annotate "High"))
                           "  deeper"))))))))

;;; Notifier

(ert-deftest harness-ui-notifier-counts-sessions ()
  (clrhash harness-ui-notifier--sessions)
  (harness-ui-notifier--on-status (list :status (list :sessionId "a" :status "blocked")))
  (harness-ui-notifier--on-status (list :status (list :sessionId "b" :status "running")))
  (harness-ui-notifier--on-status (list :status (list :sessionId "c" :status "idle" :unread 1)))
  (harness-ui-notifier--on-status (list :status (list :sessionId "d" :status "idle" :unread 0)))
  (should (equal (harness-ui-notifier-counts) '(1 1 1)))
  (let ((string (harness-ui-notifier-string)))
    (should (string-match-p "●1" string))
    (should (string-match-p "◐1" string))
    (should (string-match-p "○1" string)))
  (clrhash harness-ui-notifier--sessions)
  (should-not (harness-ui-notifier-string)))

;;; Tree

(ert-deftest harness-ui-tree-renders-and-expands ()
  (harness-ui-chat-test--stub-requests
   (list (cons "session/list" (lambda (_params) (harness-ui-chat-test--session-list)))
         (cons "_harness/session/entries"
               (lambda (_params)
                 (list :entries (vector (list :sessionUpdate "user_message_chunk"
                                              :content (list :type "text"
                                                             :text "first message"))))))
         (cons :body
               (lambda ()
                 (let ((buffer (harness-ui-tree)))
                   (harness-test-wait-for
                    (lambda () (with-current-buffer buffer (> (buffer-size) 0))) 5)
                   (with-current-buffer buffer
                     (should (string-match-p "Root" (buffer-string))))
                   ;; Expanding fetches entries and shows their summaries.
                   (harness-ui-tree-toggle-session "root")
                   (harness-test-wait-for
                    (lambda ()
                      (with-current-buffer buffer
                        (string-match-p "first message" (buffer-string))))
                    5)
                   (with-current-buffer buffer
                     (should (string-match-p "first message" (buffer-string))))
                   (kill-buffer buffer)))))))

;;; End to end through the local ACP connection

(defun harness-ui-chat-test--install-provider ()
  "Install a scripted provider for the end-to-end test."
  (harness-service-register
   "provider"
   :module 'harness-ui-chat-test
   :methods
   (list (cons 'complete
               (lambda (request)
                 (when-let* ((callback (plist-get request :on-text)))
                   (funcall callback "streamed reply"))
                 (let ((deferred (harness-deferred-new)))
                   (run-at-time 0.001 nil
                                (lambda ()
                                  (harness-deferred-resolve
                                   deferred (list :text "streamed reply"
                                                  :stop-reason "end_turn"))))
                   deferred)))
         (cons 'models (lambda (&rest _args)
                         (vector (list :id "mock/m1" :name "Mock" :provider "mock"))))
         (cons 'price (lambda (&rest _args) nil)))))

(ert-deftest harness-ui-chat-end-to-end-local ()
  "The real agent stack, driven through the local UI connection."
  (let* ((harness-session-storage-directory (make-temp-file "harness-ui-e2e-" t))
         (directory (make-temp-file "harness-ui-e2e-project-" t))
         (harness-modules '(harness-config harness-session harness-tools
                            harness-agent harness-ui harness-ui-chat)))
    (unwind-protect
        (progn
          (clrhash harness-session--active)
          (clrhash harness-session--project-ids)
          (harness-load harness-modules)
          (harness-ui-chat-test--install-provider)
          (harness-ui-start)
          (let* ((request (harness-ui-request "session/new"
                                              (list :cwd directory :mcpServers [])))
                 (created (progn (harness-test-settle request 10)
                                 (harness-deferred-value request)))
                 (session-id (plist-get created :sessionId)))
            (should session-id)
            (harness-service-call "session" 'set-config
                                  :session-id session-id
                                  :config-id "model" :value "mock/m1")
            (harness-ui-chat-open session-id 'full)
            (let ((buffer (gethash session-id harness-ui-chat--buffers)))
              (with-current-buffer buffer
                (goto-char (harness-ui-chat--compose-point))
                (insert "hello")
                (harness-ui-chat-send))
              (should (harness-test-wait-for
                       (lambda ()
                         (with-current-buffer buffer
                           (string-match-p "streamed reply"
                                           (buffer-substring-no-properties
                                            (point-min) (point-max)))))
                       15))
              (with-current-buffer buffer
                (should (string-match-p "hello"
                                        (buffer-substring-no-properties
                                         (point-min) (point-max)))))
              (kill-buffer buffer))))
      (harness-ui-stop)
      (delete-directory directory t))))


(ert-deftest harness-ui-chat-keeps-chronological-order ()
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (dolist (entry (list (list "user_message_chunk" "m1" "first message")
                           (list "agent_message_chunk" "m2" "second message")
                           (list "agent_message_chunk" "m3" "third message")))
        (harness-ui-chat-test--apply
         buffer
         (list :sessionUpdate (nth 0 entry) :messageId (nth 1 entry) :final t
               :content (list :type "text" :text (nth 2 entry)))))
      (let* ((text (harness-ui-chat-test--text buffer))
             (first (string-match "first message" text))
             (second (string-match "second message" text))
             (third (string-match "third message" text)))
        (should first)
        (should second)
        (should third)
        (should (< first second))
        (should (< second third)))
      (kill-buffer buffer))))


(ert-deftest harness-ui-chat-live-and-final-keep-order ()
  "Streaming (live) entries followed by final entries stay in order."
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (harness-ui-chat-test--apply buffer (list :sessionUpdate "user_message_chunk"
                                                :messageId "u1" :live t
                                                :content (list :type "text" :text "QUESTION")))
      (harness-ui-chat-test--apply buffer (list :sessionUpdate "user_message_chunk"
                                                :messageId "u1" :final t
                                                :content (list :type "text" :text "QUESTION")))
      (harness-ui-chat-test--apply buffer (list :sessionUpdate "agent_message_chunk"
                                                :messageId "a1" :live t :delta "ANS"
                                                :content (list :type "text" :text "ANS")))
      (harness-ui-chat-test--apply buffer (list :sessionUpdate "agent_message_chunk"
                                                :messageId "a1" :final t
                                                :content (list :type "text" :text "ANSWER")))
      (let* ((text (harness-ui-chat-test--text buffer))
             (question (string-match "QUESTION" text))
             (answer (string-match "ANSWER" text)))
        (should question)
        (should answer)
        (should (< question answer)))
      (kill-buffer buffer))))


(ert-deftest harness-ui-chat-skill-references ()
  "#name references attach skill contents to the message."
  (harness-ui-chat-test--with-stubs
    (let ((buffer (harness-ui-chat-test--buffer)))
      (with-current-buffer buffer
        (goto-char (harness-ui-chat--compose-point))
        (insert "#alpha please")
        (harness-ui-chat-send))
      (let* ((blocks (car harness-ui-chat-test--sent))
             (texts (mapcar (lambda (block) (plist-get block :text)) (append blocks nil))))
        (should (= (length texts) 2))
        (should (string-match-p "Skill `alpha`" (car texts)))
        (should (string-match-p "SKILL BODY" (car texts)))
        (should (equal (cadr texts) "#alpha please")))
      (kill-buffer buffer))))

(provide 'harness-ui-chat-test)
;;; harness-ui-chat-test.el ends here
