;;; harness-ui-compaction-ask-test.el --- Tests for the compaction question panel  -*- lexical-binding: t; -*-

;;; Commentary:

;; The panel the chat draws when the harness asks, before compacting a
;; conversation by itself, what goes first (harness-ui-compaction-ask.el):
;; the context against the window, what carrying on costs against the
;; cache, and a row per choice, its key, its button, its cost and what
;; it does.  The same question is a pending question like any other, so
;; the last test sends a message from the compose box of a session near
;; its window and answers the panel with a key.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)
(require 'harness-ui-compaction-ask)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-compaction--running)
(defvar harness-compaction--asking)
(defvar harness-tools-question--questions)
(defvar harness-non-interactive)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui--sessions)
(defvar harness-ui-default-position)
(defvar harness-chat--loading)
(defvar harness-chat--buffers)
(defvar harness-compose-end)
(defvar harness-cache-ttl-overrides)
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-chat-send "harness-ui-chat")
(declare-function harness-acp--drop-client "harness-acp")

;;;; The panel, from a record

(defun harness-ui-compaction-ask-test--choices (&optional cold)
  "Return the menu as it comes over the wire.
COLD makes the summary the one a cold prompt cache holds none of: shown,
not offered.  The harness sends the choices as a list; a vector is how a
list travels."
  (apply #'vector
         (append
          (list (if cold
                    (list :choice "summary" :key "s" :label "Summary"
                          :what "context · uncached"
                          :cost-text "no cache" :unavailable t :why "no cache")
                  (list :choice "summary" :key "s" :label "Summary"
                        :what "context · cached"
                        :cost 0.33 :cost-text "~$0.330" :after 1500)))
          (list (list :choice "transcript" :key "t" :label "Transcript"
                      :what "file" :cost 0.0 :cost-text "free")
                (list :choice "fresh" :key "f" :label "Fresh start"
                      :what "empty" :cost 0.0 :cost-text "free")
                (list :choice "carry-on" :key "c" :label "Continuation"
                      :what "context" :cost (if cold 0.315 0.025)
                      :cost-text (if cold "~$0.315 uncached" "~$0.025 cached")
                      :default t)
                (list :choice "hold" :key "q" :label "Pause"
                      :what "pause")))))

(defun harness-ui-compaction-ask-test--record (&optional cold)
  "Return the question record, as it comes over the wire.
Its `:compaction' is as a client reads it: names for symbols, vectors
for lists.  COLD makes it the question a cold prompt cache asks."
  (list :id "p-kind" :kind "question" :session-id "s1"
        :question "…"
        :options (if cold
                     ["Summary (no cache)" "Transcript (free)"
                      "Fresh start (free)" "Continuation (~$0.315 uncached · default)" "Pause"]
                   ["Summary (~$0.330)" "Transcript (free)"
                    "Fresh start (free)" "Continuation (~$0.025 cached · default)" "Pause"])
        :allow-free-text t
        :compaction (list :reason "context" :where "turn"
                          :context 84000 :window 100000 :usable 80000
                          :model "demo:scripted" :model-label "Demo scripted"
                          :cached (not cold) :carry-on (if cold 0.315 0.025)
                          :carry-on-cached 0.025
                          :default "carry-on"
                          :always '("carry-on")
                          :choices (harness-ui-compaction-ask-test--choices cold))))

(defun harness-ui-compaction-ask-test--lines (string)
  "Return the lines of STRING without its properties, trailing blanks trimmed."
  (mapcar (lambda (l) (string-trim-right l)) (split-string (substring-no-properties string) "\n")))

(defun harness-ui-compaction-ask-test--page-lines (&optional cold)
  "Return the lines of the panel, as the question sends it.
COLD makes it the question a cold prompt cache asks."
  (cl-letf (((symbol-function 'harness-compaction-history-p) (lambda (_id) t)))
    (harness-ui-compaction-ask-test--lines
     (harness-ui-compaction-ask-panel-string
      "s1" (harness-ui-compaction-ask-test--record cold)))))

(ert-deftest harness-ui-compaction-ask-panel-says-what-each-choice-costs ()
  "The panel says how full the context is, whether the prompt cache is
warm, and a row for each of the five ways -- its key, its button, its
cost and what it does, the default marked.  It is the same list the
cold-cache question asks, for its own reason.  Carrying on is the
default, and its capital is the one lasting answer: \"always carry on\"."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (let* ((lines (harness-ui-compaction-ask-test--page-lines))
         (string (cl-letf (((symbol-function 'harness-compaction-history-p)
                            (lambda (_id) t)))
                   (harness-ui-compaction-ask-panel-string
                    "s1" (harness-ui-compaction-ask-test--record)))))
    (should (equal "  Context  ~84.0k of 100k tokens · Demo scripted · cached"
                   (nth 0 lines)))
    (should (equal "" (nth 1 lines)))
    (should (equal "   Options" (nth 2 lines)))
    (should (equal '("    s  Summary       ~$0.330         context · cached"
                     "    t  Transcript    free            file"
                     "    f  Fresh start   free            empty"
                     "    c  Continuation  ~$0.025 cached  context · default"
                     "    q  Pause                         pause")
                   (seq-subseq lines 3 8)))
    (should (equal "" (nth 8 lines)))
    ;; The capital of the one lasting answer, carrying on.
    (should (equal "    C   default" (nth 9 lines)))
    (should (equal "   session_history" (nth 10 lines)))
    (should (equal "   Box key · C-c . s" (nth 11 lines)))
    ;; A session without the session_history tool says nothing about it.
    (should-not (string-match-p
                 "session_history"
                 (harness-ui-compaction-ask-panel-string
                  "s1" (harness-ui-compaction-ask-test--record))))
    ;; Nothing is a sentence: no line ends in a full stop.
    (should-not (cl-some (lambda (l) (string-match-p "[.!?]'" l)) lines))
    ;; Every character belongs to the panel, amber.
    (should (equal "p-kind" (get-text-property 0 'harness-ui-compaction-ask-panel string)))
    (should (equal "p-kind" (get-text-property 0 'harness-ui-carry-panel string)))
    (should (memq 'harness-ui-carry-face (ensure-list (get-text-property 0 'face string))))
    ;; A choice's button says more when hovered, in one exact line.
    (let* ((at (string-search "Summary" string))
           (help (get-text-property at 'help-echo string)))
      (should (equal "Summary · ~$0.330 · context · cached · ~1.5k tokens · key · s · button"
                     help)))
    (let* ((at (string-search "Continuation" string))
           (help (get-text-property at 'help-echo string)))
      (should (equal (concat "Continuation · ~$0.025 cached · context · default"
                             " · key · c · default · C · button")
                     help)))))

(ert-deftest harness-ui-compaction-ask-panel-is-one-page ()
  "The question is one page: five rows, and no span, messages, tool
detail or count page behind them."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (let ((lines (harness-ui-compaction-ask-test--page-lines)))
    (should (= 13 (length lines)))
    (should-not (cl-some (lambda (line) (string-match-p "Back\\|Done\\|Compact ·" line))
                         lines))))

(ert-deftest harness-ui-compaction-ask-panel-shows-a-cold-summary-as-not-offered ()
  "A cold prompt cache holds no summary: the same menu is shown, the
summary as a row without a key, marked not offered, and carrying on is
the default, as it is for the warm menu."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (let* ((lines (harness-ui-compaction-ask-test--page-lines t))
         (string (cl-letf (((symbol-function 'harness-compaction-history-p)
                            (lambda (_id) nil)))
                   (harness-ui-compaction-ask-panel-string
                    "s1" (harness-ui-compaction-ask-test--record t)))))
    (should (equal "  Context  ~84.0k of 100k tokens · Demo scripted · uncached"
                   (nth 0 lines)))
    (should (equal "   Options" (nth 2 lines)))
    (should (equal '("       Summary       no cache          context · uncached"
                     "    t  Transcript    free              file"
                     "    f  Fresh start   free              empty"
                     "    c  Continuation  ~$0.315 uncached  context · default"
                     "    q  Pause                           pause")
                   (seq-subseq lines 3 8)))
    ;; The summary has no key: pressing s does nothing.
    (let* ((at (string-search "Summary" string))
           (keymap (get-text-property at 'keymap string)))
      (should-not (and keymap (lookup-key keymap "s"))))
    ;; The one button it has says it is not offered.
    (should (equal "no cache"
                   (get-text-property (string-search "Summary" string) 'help-echo string)))))

(ert-deftest harness-ui-compaction-ask-panel-is-only-for-its-own-question ()
  "The panel stands in for the ordinary one only for the question that
asks what goes first before an automatic compaction."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (should (harness-ui-compaction-ask--info
           (harness-ui-compaction-ask-test--record "kind")))
  (should-not (harness-ui-compaction-ask--info
               (list :id "p2" :kind "question" :payload '(:question "Sure?"))))
  (should-not (harness-ui-compaction-ask--insert-panel
               (list :id "p2" :kind "question" :payload '(:question "Sure?")))))

;;;; In the chat

(defun harness-ui-compaction-ask-test--script (request)
  "Answer REQUEST: a summary when it asks for one, else a short reply."
  (if (string-match-p "handoff summary" (or (plist-get request :system) ""))
      '((:type text :delta "SUMMARY TEXT") (:type usage :input 50 :output 5)
        (:type done :stop-reason end-turn))
    '((:type text :delta "Done.")
      (:type usage :input 30 :output 5 :cache-read 400 :context 430)
      (:type done :stop-reason end-turn))))

(defmacro harness-ui-compaction-ask-test-with (&rest body)
  "Load the state layer with compaction and the chat with its panels; run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent compaction
                    tools-question acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-compaction--running)
     (clrhash harness-compaction--asking)
     (clrhash harness-tools-question--questions)
     (setq harness-acp--clients nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override #'harness-ui-compaction-ask-test--script)
           (harness-compaction-kind 'summary)
           (harness-compaction-ask t)
           (harness-non-interactive nil)
           (harness-acp-token nil)
           (harness-ui-default-position 'full)
           (harness-cache-ttl-overrides nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (dolist (m '(ui ui-compose ui-markdown ui-pending ui-chat ui-carry ui-compaction-ask))
         (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (unwind-protect
           (progn ,@body)
         (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) harness-chat--buffers)
         (clrhash harness-chat--buffers)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-compaction-ask-test--panel (buffer)
  "Return where BUFFER's compaction panel starts, or nil."
  (with-current-buffer buffer
    (text-property-not-all (point-min) (point-max) 'harness-ui-compaction-ask-panel nil)))

(ert-deftest harness-ui-compaction-ask-chat-asks-and-a-key-answers ()
  "A message sent to a session near its window waits on the panel, and a
key answers it: the transcript compaction is made, the message goes
after it, and the turn answers."
  (harness-ui-compaction-ask-test-with
    (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                         :model "demo:scripted" :context-window 8000)
                           :id))
           (buffer nil))
      (harness-call 'session/append sid '(:kind user :content "please refactor the parser"))
      (harness-call 'session/append sid '(:kind assistant :content "Done: parser.el rewritten"))
      ;; Over the limit: an 8000 window keeps 7000 usable.
      ;; No cache stamp: a cold cache, as after a night away.
      (harness-call 'session/usage-add sid '(:input 4000 :output 10 :context 7500))
      (setq buffer (harness-chat-buffer sid))
      (set-window-buffer (selected-window) buffer)
      (harness-test-wait (lambda () (with-current-buffer buffer
                                      (and (not harness-chat--loading) harness-compose-end)))
                         5 "the session to load")
      (with-current-buffer buffer
        (goto-char harness-compose-end)
        (insert "next question")
        (harness-chat-send))
      (harness-test-wait (lambda () (harness-ui-compaction-ask-test--panel buffer)) 5 "the compaction panel")
      (with-current-buffer buffer
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (should (string-match-p "  Context  ~7\\.5k of 8\\.0k tokens" text))
          (should (string-match-p "   Options" text))
          ;; The same menu: a summary shown, not offered, and the ways that
          ;; ask no model.
          (should (string-match-p "Summary" text))
          (should (string-match-p "no cache" text))
          (should (string-match-p "Transcript" text))
          (should (string-match-p "Fresh start" text))
          (should (string-match-p "Continuation" text)))
        ;; The ordinary question panel is not drawn as well.
        (should-not (string-search "Answer \"always\" with a choice"
                                   (buffer-substring-no-properties (point-min) (point-max))))
        (should (harness-ui-compaction-ask-waiting-p sid))
        ;; t: the transcript file.
        (let* ((at (harness-ui-compaction-ask-test--panel buffer))
               (keymap (get-text-property at 'keymap)))
          (call-interactively (lookup-key keymap "t"))))
      (harness-test-wait (lambda () (eq 'idle (plist-get (harness-call 'session/get sid) :status)))
                         10 "the turn to end")
      (should (equal "transcript" (harness-node-compaction-kind
                                   (cl-find 'compaction (harness-call 'session/nodes sid)
                                            :key (lambda (n) (plist-get n :kind))))))
      (harness-test-wait (lambda () (not (harness-ui-compaction-ask-test--panel buffer))) 5 "the panel to go")
      (should (string-match-p "next question"
                              (mapconcat (lambda (n) (or (plist-get n :content) ""))
                                         (harness-call 'session/nodes sid) "\n"))))))

(provide 'harness-ui-compaction-ask-test)
;;; harness-ui-compaction-ask-test.el ends here
