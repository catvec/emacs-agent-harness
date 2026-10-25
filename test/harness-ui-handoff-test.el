;;; harness-ui-handoff-test.el --- Tests for the question of a model switch  -*- lexical-binding: t; -*-

;;; Commentary:

;; The model-switch question as the panel that asks how to carry a
;; conversation over (harness-ui-carry.el), shown in the buffer the switch
;; started in -- a chat, the session list -- and never in the minibuffer:
;; what the switch costs, the ways to carry it over with what each costs,
;; and the keys and buttons that answer with them.  A switch of many
;; sessions has no chat of its own, so it asks in the buffer it started
;; in, else in the session list, opened for it.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)
(require 'harness-carry)
(require 'harness-ui-handoff)

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
(defvar harness-ui-sessions--buffer-name)
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-define-provider "harness-provider")

(defun harness-ui-handoff-test--define-provider ()
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

(defmacro harness-ui-handoff-test-with (&rest body)
  "Load the state layer, a hosted provider, the chat and the switch's panel; run BODY."
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
     (harness-ui-handoff-test--define-provider)
     (let ((harness-provider-demo--delay 0.005)
           (harness-naming-auto nil)
           (harness-acp-token nil)
           (harness-ui-default-position 'full)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (dolist (m '(ui ui-compose ui-markdown ui-pending ui-chat ui-sessions ui-carry ui-handoff))
         (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (unwind-protect
           ;; The minibuffer is never where the switch asks.
           (cl-letf (((symbol-function 'read-multiple-choice)
                      (lambda (&rest _) (error "The switch asked in the minibuffer"))))
             ,@body)
         (dolist (b (buffer-list))
           (when (memq (buffer-local-value 'major-mode b) '(harness-chat-mode harness-ui-sessions-mode))
             (ignore-errors (kill-buffer b))))
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-handoff-test--session ()
  "Create a demo session with one answered exchange and return its id."
  (let ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                      :model "demo:scripted")
                        :id)))
    (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt sid "fix the parser"))
                                     :stop-reason)))
    sid))

(defun harness-ui-handoff-test--chat (sid)
  "Open SID's chat buffer in the selected window and wait for it to load."
  (let ((buffer (harness-chat-buffer sid)))
    (set-window-buffer (selected-window) buffer)
    (harness-test-wait (lambda () (not (buffer-local-value 'harness-chat--loading buffer)))
                       5 "the session to load")
    buffer))

(defun harness-ui-handoff-test--text (buffer)
  "Return BUFFER's text, without properties."
  (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-handoff-test--wait-text (buffer regexp)
  "Wait until BUFFER's text matches REGEXP."
  (harness-test-wait (lambda () (string-match-p regexp (harness-ui-handoff-test--text buffer)))
                     5 (format "the buffer to show %s" regexp)))

(defun harness-ui-handoff-test--choose-hosted (command)
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

(defun harness-ui-handoff-test--press (buffer key)
  "Answer the switch question shown in BUFFER by pressing KEY."
  (with-current-buffer buffer
    (goto-char (or (harness-ui-carry-position)
                   (error "No switch question in %s" (buffer-name buffer))))
    (let ((command (key-binding (kbd key))))
      (should command)
      (call-interactively command))))

(defun harness-ui-handoff-test--asking-p (buffer)
  "Non-nil when BUFFER shows the switch question."
  (and (buffer-live-p buffer)
       (string-match-p "Switch model" (harness-ui-handoff-test--text buffer))))

(defun harness-ui-handoff-test--list-text ()
  "Return the text of the session list, or nil when there is none."
  (when-let* ((buffer (get-buffer "*harness sessions*")))
    (harness-ui-handoff-test--text buffer)))

(ert-deftest harness-ui-handoff-panel-shows-and-switches ()
  "A lossy switch shows the panel in the session's chat; its key hands over."
  (harness-ui-handoff-test-with
    (let* ((sid (harness-ui-handoff-test--session))
           (chat (harness-ui-handoff-test--chat sid)))
      (harness-ui-handoff-test--choose-hosted (lambda () (harness-set-model sid)))
      (harness-ui-handoff-test--wait-text chat "Switch model")
      (with-current-buffer chat
        (let* ((text (harness-ui-handoff-test--text chat))
               (heading (string-match "Switch model" text)))
          (should (string-match-p (regexp-quote (harness-ui-model-label "hosted:m")) text))
          (should (string-match-p "Demo scripted" text))
          (should (string-match-p "Hosted: own conversation · only the user messages after the model's last reply"
                                  text))
          ;; The risks and the concrete costs, as labelled rows.
          (dolist (risk '("Cold cache" "Fidelity" "Old state" "Timing"))
            (should (string-match-p risk text)))
          (should (string-match-p "^   Cache cost +.*list prices" text))
          ;; The ways to carry it over are those of the cold-cache question,
          ;; with their keys and what each costs.
          (should (string-match-p "^   Choose how to hand over$" text))
          (dolist (row '("^    b  Brief summary +~\\$[0-9.]+ +new model .* · narrative, tool calls in brief · first and last messages kept$"
                         "^    s  Summary +~\\$[0-9.]+ +current model Demo scripted · whole conversation · first and last messages kept$"
                         "^    t  Transcript file +free +whole conversation as a file the model reads$"
                         "^    f  Start afresh +free +nothing carried over$"
                         "^    q  Cancel +model unchanged$"))
            (should (string-match-p row text)))
          ;; The keys type in the compose box: the last line says how to
          ;; press one from there, and all of it is a panel of the box.
          (should (string-match-p "\n   from the box: C-c \\. b\n" text))
          (let ((start (harness-ui-carry-position)))
            (should (cl-loop for i from start
                             below (next-single-property-change start 'harness-ui-carry-panel nil (point-max))
                             always (equal "switch" (get-text-property i 'harness-compose-panel)))))
          ;; The panel stands out with the amber of the cold-cache question.
          (should (cl-some (lambda (f) (eq f 'harness-ui-carry-face))
                           (let ((faces (get-text-property heading 'face)))
                             (if (listp faces) faces (list faces)))))
          ;; The keys answer while point is on the panel.
          (goto-char (harness-ui-carry-position))
          (should-not (eq 'self-insert-command (key-binding (kbd "t")))))
        (harness-ui-handoff-test--press chat "t"))
      ;; The transcript went over and the panel is gone.
      (harness-test-wait (lambda () (equal "hosted:m" (plist-get (harness-call 'session/get sid) :model)))
                         10 "the switch")
      (harness-test-wait (lambda () (not (harness-ui-handoff-test--asking-p chat))) 5 "the panel to go")
      (should (harness-node-handoff (car (last (harness-call 'session/nodes sid)))))
      (should (file-exists-p (plist-get (harness-node-handoff (car (last (harness-call 'session/nodes sid))))
                                        :file))))))

(ert-deftest harness-ui-handoff-panel-cancels ()
  "The panel's cancel key leaves the model and the conversation alone."
  (harness-ui-handoff-test-with
    (let* ((sid (harness-ui-handoff-test--session))
           (chat (harness-ui-handoff-test--chat sid)))
      (harness-ui-handoff-test--choose-hosted (lambda () (harness-set-model sid)))
      (harness-ui-handoff-test--wait-text chat "Switch model")
      (harness-ui-handoff-test--press chat "q")
      (harness-test-wait (lambda () (not (harness-ui-handoff-test--asking-p chat))) 5 "the panel to go")
      (should (equal "demo:scripted" (plist-get (harness-call 'session/get sid) :model)))
      (should-not (cl-find-if #'harness-node-handoff (harness-call 'session/nodes sid))))))

(ert-deftest harness-ui-handoff-panel-keys-can-be-pressed-from-the-box ()
  "The panel's keys type in the compose box; C-c . and a key press it there.
The draft stays in the box and so does point, at the offset it had,
though the panel goes and the tail is drawn again."
  (harness-ui-handoff-test-with
    (let* ((sid (harness-ui-handoff-test--session))
           (chat (harness-ui-handoff-test--chat sid)))
      (harness-ui-handoff-test--choose-hosted (lambda () (harness-set-model sid)))
      (harness-ui-handoff-test--wait-text chat "Switch model")
      (with-current-buffer chat
        (goto-char harness-compose-end)
        (insert "draft")
        (goto-char (+ harness-compose-start 2))
        ;; Typed in the box, q types.
        (execute-kbd-macro "q")
        (should (equal "drqaft" (harness-compose-text)))
        (should (harness-ui-carry-position))
        (goto-char (+ harness-compose-start 2))
        ;; Pressed from it, q cancels the switch.
        (execute-kbd-macro (kbd "C-c . q")))
      (harness-test-wait (lambda () (not (harness-ui-handoff-test--asking-p chat))) 5 "the panel to go")
      (should (equal "demo:scripted" (plist-get (harness-call 'session/get sid) :model)))
      (with-current-buffer chat
        (should (equal "drqaft" (harness-compose-text)))
        (should (= (point) (+ harness-compose-start 2)))))))

(ert-deftest harness-ui-handoff-single-switch-from-the-session-list ()
  "A switch of the session at point, asked in the session list, asks there.
The session has a chat but the command ran in the list, which is where
the question shows: the minibuffer is never asked."
  (harness-ui-handoff-test-with
    (let* ((sid (harness-ui-handoff-test--session))
           (chat (harness-ui-handoff-test--chat sid)))
      (harness-sessions t)
      (let ((list (get-buffer "*harness sessions*")))
        (with-current-buffer list
          (goto-char (point-min))
          (while (and (not (eobp)) (not (equal (tabulated-list-get-id) sid))) (forward-line 1))
          (should (equal sid (tabulated-list-get-id)))
          (harness-ui-handoff-test--choose-hosted #'harness-set-model))
        (harness-test-wait (lambda () (with-current-buffer list (harness-ui-carry-position))) 5 "the panel in the list")
        (should-not (harness-ui-handoff-test--asking-p chat))
        (should (string-match-p "Switch model  Demo scripted → " (harness-ui-handoff-test--list-text)))
        (let ((said nil))
          (cl-letf (((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (when format-string (push (apply #'format format-string args) said)))))
            (harness-ui-handoff-test--press list "f")
            (harness-test-wait (lambda () (equal "hosted:m" (plist-get (harness-call 'session/get sid) :model)))
                               10 "the switch")
            (harness-test-wait (lambda () (with-current-buffer list (not (harness-ui-carry-position)))) 5 "the panel to go")
            ;; The harness answers once it has switched.
            (harness-test-wait (lambda () (cl-some (lambda (m) (string-prefix-p "Model → " m)) said))
                               10 "the outcome")))
        ;; Start afresh only switched.
        (should-not (cl-find-if #'harness-node-handoff (harness-call 'session/nodes sid)))))))

(ert-deftest harness-ui-handoff-no-chat-asks-in-the-session-list ()
  "Without a chat buffer, and from no buffer that can show it, the switch
asks in the session list, shown for it, and not in the minibuffer."
  (harness-ui-handoff-test-with
    (let ((sid (harness-ui-handoff-test--session)))
      (should-not (get-buffer "*harness sessions*"))
      (with-temp-buffer
        (harness-ui-handoff-test--choose-hosted (lambda () (harness-set-model sid))))
      (harness-test-wait (lambda () (and (get-buffer "*harness sessions*")
                                         (with-current-buffer "*harness sessions*" (harness-ui-carry-position))))
                         5 "the panel in the session list")
      (should (get-buffer-window "*harness sessions*" t))
      (harness-ui-handoff-test--press (get-buffer "*harness sessions*") "t")
      (harness-test-wait (lambda () (equal "hosted:m" (plist-get (harness-call 'session/get sid) :model)))
                         10 "the switch"))))

(ert-deftest harness-ui-handoff-panel-for-a-batch ()
  "A switch of many shows one panel, naming the sessions that lose their conversation."
  (harness-ui-handoff-test-with
    (let* ((one (harness-ui-handoff-test--session))
           (two (harness-ui-handoff-test--session))
           (chat (harness-ui-handoff-test--chat one)))
      (with-current-buffer chat
        (harness-ui-handoff-test--choose-hosted #'harness-set-model-all))
      (harness-ui-handoff-test--wait-text chat "Switch model")
      (with-current-buffer chat
        (let ((text (harness-ui-handoff-test--text chat)))
          (should (string-match-p "2 sessions" text))
          (should (string-match-p "^   Sessions +.* · 2 of 2 change$" text))))
      (harness-ui-handoff-test--press chat "t")
      (harness-test-wait (lambda () (and (equal "hosted:m" (plist-get (harness-call 'session/get one) :model))
                                         (equal "hosted:m" (plist-get (harness-call 'session/get two) :model))))
                         10 "both sessions to switch")
      (harness-test-wait (lambda () (not (harness-ui-handoff-test--asking-p chat))) 5 "the panel to go")
      (dolist (sid (list one two))
        (should (harness-node-handoff (car (last (harness-call 'session/nodes sid)))))))))

(ert-deftest harness-ui-handoff-batch-with-no-chat-buffer ()
  "A switch of every session, started from a buffer that cannot show the
question, with no chat buffer open at all, asks in the session list.
Each way costs what it costs for all the sessions, and the answer
switches them all."
  (harness-ui-handoff-test-with
    (let* ((one (harness-ui-handoff-test--session))
           (two (harness-ui-handoff-test--session)))
      (should-not (cl-some (lambda (b) (eq 'harness-chat-mode (buffer-local-value 'major-mode b))) (buffer-list)))
      (with-temp-buffer
        (harness-ui-handoff-test--choose-hosted #'harness-set-model-all))
      (harness-test-wait (lambda () (and (get-buffer "*harness sessions*")
                                         (with-current-buffer "*harness sessions*" (harness-ui-carry-position))))
                         5 "the panel in the session list")
      (let* ((list (get-buffer "*harness sessions*"))
             (text (harness-ui-handoff-test--list-text)))
        (should (string-match-p "Switch model  2 sessions → " text))
        (should (string-match-p "^   Sessions +.* · 2 of 2 change$" text))
        ;; The panel is above the rows; point is on it.
        (should (< (harness-ui-carry-position list) (string-match-p " idle " text)))
        (should (with-current-buffer list (harness-ui-carry-on-panel-p)))
        ;; No compose box in the list to press a key from.
        (should-not (string-match-p "from the box" text))
        ;; What each way costs is the sum for both sessions.
        (let* ((per-session (plist-get (car (harness-call 'handoff/check-all "hosted:m")) :choices))
               (brief (plist-get (cl-find "brief" per-session :key (lambda (c) (plist-get c :choice)) :test #'equal)
                                 :cost)))
          (should (string-match-p (regexp-quote (format "~%s" (harness-format-cost (* 2 brief)))) text)))
        (harness-ui-handoff-test--press list "t")
        (harness-test-wait (lambda () (and (equal "hosted:m" (plist-get (harness-call 'session/get one) :model))
                                           (equal "hosted:m" (plist-get (harness-call 'session/get two) :model))))
                           10 "both sessions to switch")
        (dolist (sid (list one two))
          (should (harness-node-handoff (car (last (harness-call 'session/nodes sid))))))
        (harness-test-wait (lambda () (with-current-buffer list (not (harness-ui-carry-position)))) 5 "the panel to go")))))

(ert-deftest harness-ui-handoff-batch-from-the-marked-sessions ()
  "The marked sessions of the list switch together: the question is above
the rows of the list the command ran in, and cancelling changes nothing."
  (harness-ui-handoff-test-with
    (let* ((one (harness-ui-handoff-test--session))
           (two (harness-ui-handoff-test--session)))
      (harness-sessions t)
      (let ((list (get-buffer "*harness sessions*")))
        (with-current-buffer list
          (harness-ui-sessions--mark one)
          (harness-ui-sessions--mark two)
          (harness-ui-handoff-test--choose-hosted #'harness-set-model))
        (harness-test-wait (lambda () (with-current-buffer list (harness-ui-carry-position))) 5 "the panel in the list")
        (should (string-match-p "Switch model  2 sessions → " (harness-ui-handoff-test--list-text)))
        (harness-ui-handoff-test--press list "q")
        (harness-test-wait (lambda () (with-current-buffer list (not (harness-ui-carry-position)))) 5 "the panel to go")
        (dolist (sid (list one two))
          (should (equal "demo:scripted" (plist-get (harness-call 'session/get sid) :model))))))))

(ert-deftest harness-ui-handoff-the-list-keeps-point-on-the-panel-when-it-redraws ()
  "The session list follows the sessions as they change; point stays on
the panel it asks in, and goes back to the panel if the redraw moved it."
  (harness-ui-handoff-test-with
    (let* ((one (harness-ui-handoff-test--session))
           (two (harness-ui-handoff-test--session)))
      (ignore two)
      (with-temp-buffer
        (harness-ui-handoff-test--choose-hosted #'harness-set-model-all))
      (harness-test-wait (lambda () (and (get-buffer "*harness sessions*")
                                         (with-current-buffer "*harness sessions*" (harness-ui-carry-position))))
                         5 "the panel in the session list")
      (let ((list (get-buffer "*harness sessions*")))
        (with-current-buffer list
          (should (harness-ui-carry-on-panel-p))
          (harness-ui-sessions--redraw)
          (should (harness-ui-carry-on-panel-p))
          ;; Point on a row stays on that row, the panel above it.
          (goto-char (harness-ui-sessions--position one))
          (should (equal one (tabulated-list-get-id)))
          (harness-ui-sessions--redraw)
          (should (equal one (tabulated-list-get-id)))
          (should (harness-ui-carry-position)))
        (harness-ui-handoff-test--press list "q")))))

(ert-deftest harness-ui-handoff-panel-and-an-expired-cache ()
  "Asked to switch once the cache lapsed, the summary says it reads it all
uncached, not that its cache is warm, and the cache panel stays away
while it asks: what the next message sends depends on the answer.
Cancelled, the cache panel is back; switched with a handoff, the new
conversation has nothing cached and no panel shows."
  (harness-ui-handoff-test-with
    (harness-test-load-module 'ui-cache)
    (let* ((harness-cache-ttl 1)
           (harness-cache-ttl-overrides nil)
           (sid (harness-ui-handoff-test--session))
           (chat (harness-ui-handoff-test--chat sid)))
      (harness-call 'session/usage-add sid '(:input 10 :output 10 :cache-read 900 :context 920))
      (harness-ui-handoff-test--wait-text chat "Prompt cache expired")
      (harness-ui-handoff-test--choose-hosted (lambda () (harness-set-model sid)))
      (harness-ui-handoff-test--wait-text chat "Switch model")
      (let ((text (harness-ui-handoff-test--text chat)))
        (should (string-match-p "current model Demo scripted · whole conversation · first and last messages kept · cache expired at [0-9:]+ · all uncached"
                                text))
        (should-not (string-match-p "cache warm" text))
        (should-not (string-match-p "Prompt cache expired" text)))
      (harness-ui-handoff-test--press chat "q")
      (harness-ui-handoff-test--wait-text chat "Prompt cache expired")
      (should-not (harness-ui-handoff-test--asking-p chat))
      (harness-ui-handoff-test--choose-hosted (lambda () (harness-set-model sid)))
      (harness-ui-handoff-test--wait-text chat "Switch model")
      (harness-ui-handoff-test--press chat "t")
      (harness-test-wait (lambda () (equal "hosted:m" (plist-get (harness-call 'session/get sid) :model)))
                         10 "the switch")
      (harness-test-wait (lambda () (not (string-match-p "Switch model\\|Prompt cache"
                                                         (harness-ui-handoff-test--text chat))))
                         5 "the panel and the cache panel to go")
      (should-not (plist-get (harness-call 'session/get sid) :cache)))))

(defun harness-ui-handoff-test--check (cache &rest props)
  "Return a lossy `handoff/check' answer for a session whose cache is CACHE.
It carries the choices the harness sends: a summary that costs 1 cent
while the cache lasts and 10 once it lapsed, and a brief one that costs 2.
PROPS are put over what it says."
  (append props
          (list :id "s1" :name "Fix it" :lossy t :from "a:m" :from-label "Model A" :cache cache
                :choices (list (harness-carry-switch-choice 'brief :cost 0.02)
                               (harness-carry-switch-choice 'summary :cost 0.01 :cost-uncached 0.10)
                               (harness-carry-switch-choice 'transcript :cost 0.0)
                               (harness-carry-switch-choice 'fresh :cost 0.0)
                               (harness-carry-switch-choice 'hold)))))

(ert-deftest harness-ui-handoff-summary-says-when-the-cache-is-cold ()
  "Summarising on the current model is cheap while that model's cache is
warm, so the choice says when it is not: it lapsed, or it is another
model's.  Where nothing is known it says nothing of the cache, and with
every cache warm it says so."
  (let* ((now 10000.0)
         (warm '(:from "a:m" :cache (:at 9900.0 :ttl 300 :expires 10200.0 :model "a:m")))
         (expired '(:from "a:m" :cache (:at 9000.0 :ttl 300 :expires 9300.0 :model "a:m")))
         (other '(:from "a:m" :cache (:at 9900.0 :ttl 300 :expires 10200.0 :model "b:m")))
         (unknown '(:from "a:m"))
         (note (lambda (&rest checks) (harness-ui-handoff--cache-note checks now))))
    (should (equal "cache warm" (funcall note warm)))
    (should (equal "cache warm" (funcall note warm warm)))
    (should-not (funcall note unknown))
    (should-not (funcall note warm unknown))
    (should (equal (format "cache expired at %s · all uncached" (harness-ui-format-clock 9300.0 now))
                   (funcall note expired)))
    (should (equal "cache cold · all uncached" (funcall note other)))
    (should (equal "caches expired · all uncached" (funcall note expired other)))
    (should (equal "uncached where the cache lapsed (1 of 3)" (funcall note warm expired unknown)))
    ;; Nouns, not sentences.
    (dolist (text (list (funcall note expired) (funcall note other) (funcall note expired other)
                        (funcall note warm expired unknown)))
      (should-not (string-match-p "[.!?]" text)))))

(ert-deftest harness-ui-handoff-cache-note-does-not-call-the-cache-of-a-running-turn-expired ()
  "A session whose turn runs reads its cache with every request: it is not called lapsed.
The stamp of a hosted loop (Claude Code) is the turn before's until the
turn says its next request, and a switch made then summarises at the
turn's next step, from a cache the turn has just used.  The panel would
have said the cache expired at a moment before the turn began: a false
alarm.  What the stamp says of another model's cache holds whatever the
turn does, and so does a cache that is warm."
  (let* ((now 10000.0)
         (expired '(:from "a:m" :running t :cache (:at 9000.0 :ttl 300 :expires 9300.0 :model "a:m")))
         (idle (plist-put (copy-sequence expired) :running nil))
         (other '(:from "a:m" :running t :cache (:at 9900.0 :ttl 300 :expires 10200.0 :model "b:m")))
         (warm '(:from "a:m" :running t :cache (:at 9900.0 :ttl 300 :expires 10200.0 :model "a:m")))
         (note (lambda (&rest checks) (harness-ui-handoff--cache-note checks now))))
    ;; The same stamp, said of an idle session, is a lapsed cache.
    (should (equal (format "cache expired at %s · all uncached" (harness-ui-format-clock 9300.0 now))
                   (funcall note idle)))
    (should-not (funcall note expired))
    (should (equal "cache warm" (funcall note warm)))
    (should (equal "cache cold · all uncached" (funcall note other)))
    ;; A batch counts the lapsed caches of the sessions that wait.
    (should (equal "uncached where the cache lapsed (1 of 2)" (funcall note idle expired)))
    (should-not (funcall note expired expired))))

(ert-deftest harness-ui-handoff-cache-note-says-when-a-redaction-dropped-the-cache ()
  "A cache a redaction dropped (the check's `:cache' has `:dropped') is not one that lapsed.
Asked about one session, the choice says when the redaction dropped it,
as the cache panel does, and that everything is sent uncached.  Every
other case reads as it did: a lapsed cache, another model's cache -- the
cache a redaction dropped of a model the session left is that, first --
a batch, and a cache that still lasts."
  (let* ((now (+ 10000.0 86400.0))
         (dropped '(:from "a:m" :cache (:at 9000.0 :ttl 300 :expires 10100.0 :model "a:m" :dropped 10100.0)))
         (lapsed '(:from "a:m" :cache (:at 9000.0 :ttl 300 :expires 9300.0 :model "a:m")))
         (other '(:from "a:m" :cache (:at 9000.0 :ttl 300 :expires 10100.0 :model "b:m" :dropped 10100.0)))
         (warm (list :from "a:m" :cache (list :at (- now 10) :ttl 300 :expires (+ now 290) :model "a:m")))
         (note (lambda (&rest checks) (harness-ui-handoff--cache-note checks now)))
         (clock (harness-ui-format-clock 10100.0 now)))
    ;; The drop is said with its moment, which is the cache's `:expires', and by whom.
    (should (equal (format "cache dropped at %s by a redaction · all uncached" clock) (funcall note dropped)))
    (should (equal (format "cache dropped at %s by a redaction · all uncached"
                           (harness-ui-format-clock 10100.0 10200.0))
                   (harness-ui-handoff--cache-note (list dropped) 10200.0)))
    ;; Not the words for a cache that lapsed by itself, which read as they did.
    (should (equal (format "cache expired at %s · all uncached" (harness-ui-format-clock 9300.0 now))
                   (funcall note lapsed)))
    (should (equal "cache cold · all uncached" (funcall note other)))
    ;; A batch says only how many lapsed, as ever.
    (should (equal "caches expired · all uncached" (funcall note dropped lapsed)))
    (should (equal "caches expired · all uncached" (funcall note dropped dropped)))
    (should (equal "uncached where the cache lapsed (1 of 2)" (funcall note warm dropped)))
    (should (equal "cache warm" (funcall note warm)))))

(ert-deftest harness-ui-handoff-the-summary-costs-what-its-cache-lets-it ()
  "The summary on the current model costs what the check says while the
cache lasts, and what it says of a cache that lapsed once it did, as of
when the panel is drawn; the other choices cost the same either way.  A
batch costs the sum for all its sessions, nothing where a price is not
known."
  (let* ((now 10000.0)
         (warm (harness-ui-handoff-test--check '(:at 9900.0 :ttl 300 :expires 10200.0 :model "a:m")))
         (expired (harness-ui-handoff-test--check '(:at 9000.0 :ttl 300 :expires 9300.0 :model "a:m")))
         (running (harness-ui-handoff-test--check '(:at 9000.0 :ttl 300 :expires 9300.0 :model "a:m") :running t))
         (unknown (harness-ui-handoff-test--check nil))
         (cost (lambda (name &rest checks)
                 (plist-get (cl-find name (harness-ui-handoff--choices checks "Model B" now)
                                     :key (lambda (c) (plist-get c :choice)) :test #'equal)
                            :cost-text))))
    (should (equal "~$0.010" (funcall cost "summary" warm)))
    (should (equal "~$0.100" (funcall cost "summary" expired)))
    (should (equal "~$0.010" (funcall cost "summary" running)))
    (should (equal "~$0.010" (funcall cost "summary" unknown)))
    ;; Both of a batch: one cent where it is warm, 10 where it lapsed.
    (should (equal "~$0.110" (funcall cost "summary" warm expired)))
    (should (equal "~$0.020" (funcall cost "brief" expired)))
    (should (equal "~$0.040" (funcall cost "brief" warm expired)))
    (should (equal "free" (funcall cost "transcript" warm expired)))
    (should (equal "free" (funcall cost "fresh" expired)))
    (should-not (funcall cost "hold" expired))
    ;; A session whose model is not priced makes the total unknown.
    (let ((unpriced (harness-ui-handoff-test--check
                     nil :choices (list (harness-carry-switch-choice 'brief)
                                        (harness-carry-switch-choice 'summary)
                                        (harness-carry-switch-choice 'transcript)
                                        (harness-carry-switch-choice 'fresh)
                                        (harness-carry-switch-choice 'hold)))))
      (should-not (funcall cost "summary" warm unpriced))
      (should (equal "free" (funcall cost "transcript" warm unpriced))))))

(ert-deftest harness-ui-handoff-choices-say-who-writes-and-answer-with-modes ()
  "The two summaries say which model writes them, the current one or the
new, and each choice hands over by the mode the harness named; a check
that brings no choices gets the table's, with the same modes."
  (let* ((check (harness-ui-handoff-test--check nil))
         (choices (harness-ui-handoff--choices (list check) "Model B" 10000.0)))
    (should (equal '("brief" "summary" "transcript" "fresh" "hold")
                   (mapcar (lambda (c) (plist-get c :choice)) choices)))
    (should (equal '("new model Model B" "current model Model A" nil nil nil)
                   (mapcar (lambda (c) (plist-get c :by)) choices)))
    (should (equal "Cancel" (plist-get (car (last choices)) :label)))
    (should (equal "model unchanged" (plist-get (car (last choices)) :what)))
    (dolist (entry '(("brief" . compact-new) ("summary" . compact) ("transcript" . transcript)
                     ("fresh" . none) ("hold" . cancel) ("nonsense" . cancel)))
      (should (eq (cdr entry) (harness-ui-handoff--mode (list check) (car entry)))))
    ;; A harness that sends no choices: the table's.
    (let* ((bare (list :id "s1" :lossy t :from "a:m"))
           (choices (harness-ui-handoff--choices (list bare) "Model B" 10000.0)))
      (should (equal '("b" "s" "t" "f" "q") (mapcar (lambda (c) (plist-get c :key)) choices)))
      (should (eq 'compact-new (harness-ui-handoff--mode (list bare) "brief")))
      (should (eq 'cancel (harness-ui-handoff--mode (list bare) "hold"))))
    ;; Two sessions of different models: no one model writes the summary.
    (let ((choices (harness-ui-handoff--choices
                    (list check (harness-ui-handoff-test--check nil :from-label "Model C" :id "s2" :from "c:m"))
                    "Model B" 10000.0)))
      (should (equal "each current model" (plist-get (nth 1 choices) :by))))))

(ert-deftest harness-ui-handoff-facts-name-a-few-sessions-and-count-the-rest ()
  "A batch names the first sessions that lose their conversation, counts
the others, and says how many change in all: one fact, not a page."
  (let* ((checks (mapcar (lambda (n) (harness-ui-handoff-test--check nil :id (format "s%d" n) :name (format "Task %d" n)))
                         (number-sequence 1 10)))
         (row (cadr (assoc "Sessions" (harness-ui-handoff--facts checks 14)))))
    (should (equal (concat "“Task 1” · “Task 2” · “Task 3” · “Task 4” · “Task 5” · “Task 6”"
                           " · 4 more · 10 of 14 change")
                   row))
    ;; One session names no batch, and shows what the new model's cold cache costs.
    (let ((facts (harness-ui-handoff--facts (list (harness-ui-handoff-test--check
                                                   nil :cache-cost "1k tokens: $0.01 to write, $0.001 to read"
                                                   :risks '("Timing: next step, not mid-step")
                                                   :running t))
                                            1)))
      (should (equal '(("Timing" "next step, not mid-step")
                       ("Cache cost" "1k tokens: $0.01 to write, $0.001 to read (list prices)")
                       ("Turn" "running · switch at its next step"))
                     facts)))))

(ert-deftest harness-ui-handoff-cancels-when-nothing-can-show-the-question ()
  "With no buffer to show the question in, the switch is cancelled with a
word, and nothing is asked in the minibuffer."
  (let ((answer nil) (said nil))
    (cl-letf (((symbol-function 'harness-ui-carry-host) (lambda (&rest _) nil))
              ((symbol-function 'read-multiple-choice)
               (lambda (&rest _) (error "The switch asked in the minibuffer")))
              ((symbol-function 'message)
               (lambda (format-string &rest args) (push (apply #'format format-string args) said))))
      (harness-ui-handoff--ask (list (harness-ui-handoff-test--check nil)) "Model B" 1 "s1" nil
                               (lambda (mode) (setq answer mode))))
    (should (eq 'cancel answer))
    (should (equal '("Model unchanged: no buffer to ask in") said))))

(provide 'harness-ui-handoff-test)
;;; harness-ui-handoff-test.el ends here
