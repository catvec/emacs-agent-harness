;;; harness-ui-switch-test.el --- Tests for the switch banner  -*- lexical-binding: t; -*-

;;; Commentary:

;; The model-switch question as a banner in the session's chat: what the
;; switch costs, the ways to hand the conversation over, and the keys and
;; buttons that answer with them.  A harness with no chat buffer to show
;; the banner in asks in the minibuffer instead.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-compaction--running)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui--sessions)
(defvar harness-ui--models)
(defvar harness-ui-default-position)
(defvar harness-chat--loading)
(defvar harness-chat-mode)
(defvar harness-cache-ttl)
(defvar harness-cache-ttl-overrides)
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-define-provider "harness-provider")

(defun harness-ui-switch-test--define-provider ()
  "Define `hosted', a hosted loop to switch sessions to."
  (harness-define-provider 'hosted
    :label "Hosted"
    :models (lambda ()
              (harness-resolved
               (list (list :name "m" :label "Hosted M"
                           :pricing '(:input 4.0 :output 20.0 :cache-read 0.2 :cache-write 5.0)))))
    :complete (lambda (req)
                (let ((on-event (plist-get req :on-event)))
                  (run-at-time 0.005 nil
                               (lambda ()
                                 (funcall on-event '(:type provider-state :state (:conv "c1")))
                                 (funcall on-event '(:type text :delta "ok"))
                                 (funcall on-event '(:type done :stop-reason end-turn)))))
                (list :cancel #'ignore))
    :capabilities '(:hosted-loop t :resume t)))

(defmacro harness-ui-switch-test-with (&rest body)
  "Load the state layer, a hosted provider and the chat with the switch banner, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent compaction handoff acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-compaction--running)
     (setq harness-acp--clients nil)
     (harness-ui-switch-test--define-provider)
     (let ((harness-provider-demo--delay 0.005)
           (harness-naming-auto nil)
           (harness-acp-token nil)
           (harness-ui-default-position 'full)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (dolist (m '(ui ui-compose ui-markdown ui-chat ui-switch))
         (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (unwind-protect
           (progn ,@body)
         (dolist (b (buffer-list))
           (when (eq (buffer-local-value 'major-mode b) 'harness-chat-mode)
             (ignore-errors (kill-buffer b))))
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-switch-test--session ()
  "Create a demo session with one answered exchange and return its id."
  (let ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                      :model "demo:scripted")
                        :id)))
    (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt sid "fix the parser"))
                                     :stop-reason)))
    sid))

(defun harness-ui-switch-test--chat (sid)
  "Open SID's chat buffer in the selected window and wait for it to load."
  (let ((buffer (harness-chat-buffer sid)))
    (set-window-buffer (selected-window) buffer)
    (harness-test-wait (lambda () (not (buffer-local-value 'harness-chat--loading buffer)))
                       5 "the session to load")
    buffer))

(defun harness-ui-switch-test--text (buffer)
  "Return BUFFER's text, without properties."
  (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-switch-test--wait-text (buffer regexp)
  "Wait until BUFFER's text matches REGEXP."
  (harness-test-wait (lambda () (string-match-p regexp (harness-ui-switch-test--text buffer)))
                     5 (format "the buffer to show %s" regexp)))

(defun harness-ui-switch-test--choose-hosted (command)
  "Run COMMAND, answering its model prompt with the hosted model."
  (cl-letf (((symbol-function 'harness-ui-refresh-models)
             (lambda (&optional callback)
               (let ((models (list (list :id "hosted:m" :label "Hosted M"
                                         :provider-label "Hosted" :context-window 1000000))))
                 (clrhash harness-ui--models)
                 (dolist (m models) (puthash (plist-get m :id) m harness-ui--models))
                 (when callback (funcall callback models)))))
            ((symbol-function 'completing-read) (lambda (_prompt table &rest _) (caar table))))
    (funcall command)))

(defun harness-ui-switch-test--press (buffer key)
  "Answer the switch banner in BUFFER by pressing KEY."
  (with-current-buffer buffer
    (goto-char (or (harness-ui-switch--banner-pos)
                   (error "No switch banner in %s" (buffer-name buffer))))
    (let ((command (key-binding (kbd key))))
      (should command)
      (call-interactively command))))

(ert-deftest harness-ui-switch-banner-shows-and-switches ()
  "A lossy switch shows a banner in the session's chat; its key hands over."
  (harness-ui-switch-test-with
    (let* ((sid (harness-ui-switch-test--session))
           (chat (harness-ui-switch-test--chat sid)))
      (harness-ui-switch-test--choose-hosted (lambda () (harness-set-model sid)))
      (harness-ui-switch-test--wait-text chat "Switch model")
      (with-current-buffer chat
        (let* ((text (harness-ui-switch-test--text chat))
               (heading (string-match "Switch model" text)))
          (should (string-match-p (regexp-quote (harness-ui-model-label "hosted:m")) text))
          (should (string-match-p "Demo scripted" text))
          (should (string-match-p "sent only the user messages after the model's last reply" text))
          ;; The risks and the concrete costs, as labelled rows.
          (dolist (risk '("Cold cache" "Fidelity" "Old state" "Timing"))
            (should (string-match-p risk text)))
          (should (string-match-p "^   Cost +.*list prices" text))
          ;; Each way to hand over, with its key.
          (dolist (option '("current model summarises" "new model summarises" "full transcript"
                            "no handoff" "cancel"))
            (should (string-match-p (regexp-quote option) text)))
          (dolist (key '("c" "n" "t" "s" "q"))
            (should (string-match-p (format "[ ]%s[ ]" key) text)))
          ;; The banner stands out with its own background.
          (should (cl-some (lambda (f) (eq f 'harness-chat-switch-face))
                           (let ((faces (get-text-property heading 'face)))
                             (if (listp faces) faces (list faces)))))
          ;; The keys answer while point is on the banner.
          (goto-char (harness-ui-switch--banner-pos))
          (should-not (eq 'self-insert-command (key-binding (kbd "t")))))
        (harness-ui-switch-test--press chat "t"))
      ;; The transcript went over and the banner is gone.
      (harness-test-wait (lambda () (equal "hosted:m" (plist-get (harness-call 'session/get sid) :model)))
                         10 "the switch")
      (harness-test-wait (lambda () (not (string-match-p "Switch model"
                                                         (harness-ui-switch-test--text chat))))
                         5 "the banner to go")
      (should (harness-node-handoff (car (last (harness-call 'session/nodes sid)))))
      (should (file-exists-p (plist-get (harness-node-handoff (car (last (harness-call 'session/nodes sid))))
                                        :file))))))

(ert-deftest harness-ui-switch-banner-cancels ()
  "The banner's cancel key leaves the model and the conversation alone."
  (harness-ui-switch-test-with
    (let* ((sid (harness-ui-switch-test--session))
           (chat (harness-ui-switch-test--chat sid)))
      (harness-ui-switch-test--choose-hosted (lambda () (harness-set-model sid)))
      (harness-ui-switch-test--wait-text chat "Switch model")
      (harness-ui-switch-test--press chat "q")
      (harness-test-wait (lambda () (not (string-match-p "Switch model"
                                                         (harness-ui-switch-test--text chat))))
                         5 "the banner to go")
      (should (equal "demo:scripted" (plist-get (harness-call 'session/get sid) :model)))
      (should-not (cl-find-if #'harness-node-handoff (harness-call 'session/nodes sid))))))

(ert-deftest harness-ui-switch-no-chat-asks-in-the-minibuffer ()
  "Without a chat buffer the switch asks in the minibuffer, as before."
  (harness-ui-switch-test-with
    (let ((sid (harness-ui-switch-test--session))
          (asked nil))
      (cl-letf (((symbol-function 'read-multiple-choice)
                 (lambda (_prompt choices &optional _help &rest _)
                   (setq asked choices)
                   (assq ?s choices))))
        (harness-ui-switch-test--choose-hosted (lambda () (harness-set-model sid)))
        ;; The check comes back asynchronously: the question arrives (and is
        ;; answered) while the mock is still in place.
        (harness-test-wait (lambda () asked) 5 "the minibuffer question")
        (should asked))
      (harness-test-wait (lambda () (equal "hosted:m" (plist-get (harness-call 'session/get sid) :model)))
                         10 "the switch"))))

(ert-deftest harness-ui-switch-banner-for-a-batch ()
  "A switch of many shows one banner, naming the sessions that lose their conversation."
  (harness-ui-switch-test-with
    (let* ((one (harness-ui-switch-test--session))
           (two (harness-ui-switch-test--session))
           (chat (harness-ui-switch-test--chat one)))
      (with-current-buffer chat
        (harness-ui-switch-test--choose-hosted #'harness-set-model-all))
      (harness-ui-switch-test--wait-text chat "Switch model")
      (with-current-buffer chat
        (let ((text (harness-ui-switch-test--text chat)))
          (should (string-match-p "2 sessions" text))
          (should (string-match-p "^   Sessions +" text))
          (should (string-match-p "(2 of 2 change)" text))))
      (harness-ui-switch-test--press chat "t")
      (harness-test-wait (lambda () (and (equal "hosted:m" (plist-get (harness-call 'session/get one) :model))
                                         (equal "hosted:m" (plist-get (harness-call 'session/get two) :model))))
                         10 "both sessions to switch")
      (harness-test-wait (lambda () (not (string-match-p "Switch model"
                                                         (harness-ui-switch-test--text chat))))
                         5 "the banner to go")
      (dolist (sid (list one two))
        (should (harness-node-handoff (car (last (harness-call 'session/nodes sid)))))))))

(ert-deftest harness-ui-switch-banner-and-an-expired-cache ()
  "Asked to switch once the cache lapsed, the banner says a summary on the
current model reads it all again uncached, not that its cache is warm,
and the cache panel stays away while it asks: what the next message
sends depends on the answer.  Cancelled, the panel is back; switched
with a handoff, the new conversation has nothing cached and no panel
shows."
  (harness-ui-switch-test-with
    (harness-test-load-module 'ui-cache)
    (let* ((harness-cache-ttl 1)
           (harness-cache-ttl-overrides nil)
           (sid (harness-ui-switch-test--session))
           (chat (harness-ui-switch-test--chat sid)))
      (harness-call 'session/usage-add sid '(:input 10 :output 10 :cache-read 900 :context 920))
      (harness-ui-switch-test--wait-text chat "Prompt cache expired")
      (harness-ui-switch-test--choose-hosted (lambda () (harness-set-model sid)))
      (harness-ui-switch-test--wait-text chat "Switch model")
      (let ((text (harness-ui-switch-test--text chat)))
        (should (string-match-p "current model summarises +cache expired at [0-9:]+: re-reads it all uncached"
                                text))
        (should-not (string-match-p "warm cache" text))
        (should-not (string-match-p "Prompt cache expired" text)))
      (harness-ui-switch-test--press chat "q")
      (harness-ui-switch-test--wait-text chat "Prompt cache expired")
      (should-not (string-match-p "Switch model" (harness-ui-switch-test--text chat)))
      (harness-ui-switch-test--choose-hosted (lambda () (harness-set-model sid)))
      (harness-ui-switch-test--wait-text chat "Switch model")
      (harness-ui-switch-test--press chat "t")
      (harness-test-wait (lambda () (equal "hosted:m" (plist-get (harness-call 'session/get sid) :model)))
                         10 "the switch")
      (harness-test-wait (lambda () (not (string-match-p "Switch model\\|Prompt cache"
                                                         (harness-ui-switch-test--text chat))))
                         5 "the banner and the panel to go")
      (should-not (plist-get (harness-call 'session/get sid) :cache)))))

(provide 'harness-ui-switch-test)
;;; harness-ui-switch-test.el ends here
