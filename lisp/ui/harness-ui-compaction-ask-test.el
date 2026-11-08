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

(defun harness-ui-compaction-ask-test--choices ()
  "Return the choices of a priced question, as they come over the wire.
The harness sends them as a list; a vector is how a list travels."
  (apply #'vector
         (list (list :choice "brief" :key "b" :label "Brief summary"
                     :what "narrative, tool calls in brief · read uncached · first and last messages kept"
                     :cost 0.004 :cost-text "~$0.0040" :after 900)
               (list :choice "summary" :key "s" :label "Summary"
                     :what "whole conversation · read uncached · first and last messages kept"
                     :cost 0.33 :cost-text "~$0.330" :after 1500)
               (list :choice "transcript" :key "t" :label "Transcript file"
                     :what "whole conversation as a file the model reads"
                     :cost 0.0 :cost-text "free" :after 200)
               (list :choice "fresh" :key "f" :label "Start afresh"
                     :what "nothing carried over" :cost 0.0 :cost-text "free" :after 90)
               (list :choice "truncate" :key "x" :label "Cut old context"
                     :what "oldest messages dropped · newest kept as they are"
                     :cost 0.0 :cost-text "free" :after 9000)
               (list :choice "carry-on" :key "c" :label "Carry on"
                     :what "whole conversation again, uncached"
                     :cost 0.315 :cost-text "~$0.315 uncached")
               (list :choice "hold" :key "q" :label "Not now"
                     :what "message waits"))))

(defun harness-ui-compaction-ask-test--record (&rest overrides)
  "Return a compaction question record as the UI keeps it, with OVERRIDES.
Its `:compaction' is as it comes over the wire: names for symbols,
vectors for lists."
  (harness-plist-merge
   (list :id "p1" :kind "question" :session-id "s1"
         :question "The conversation is ~84.0k tokens of this model's ~100k window.  …"
         :options ["Brief summary (~$0.0040)" "Summary (~$0.330, the default)" "Transcript file (free)"
                   "Start afresh (free)" "Cut old context (free)" "Carry on (~$0.315 uncached)" "Not now"]
         :allow-free-text t
         :compaction (list :reason "context" :where "turn" :context 84000 :window 100000
                           :usable 80000 :model "demo:scripted" :model-label "Demo scripted"
                           :cached t :carry-on 0.315 :carry-on-cached 0.025 :default "summary"
                           :choices (harness-ui-compaction-ask-test--choices)))
   overrides))

(defun harness-ui-compaction-ask-test--lines (string)
  "Return the lines of STRING without its properties, trailing blanks trimmed."
  (mapcar (lambda (l) (string-trim-right l)) (split-string (substring-no-properties string) "\n")))

(ert-deftest harness-ui-compaction-ask-panel-says-what-each-choice-costs ()
  "The panel says how full the context is, what carrying on costs against
the cache, and a row per choice: its key, its button, its cost and what
it does, the default marked.  It offers no \"always\": every automatic
compaction is the user's to decide."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (let* ((string (cl-letf (((symbol-function 'harness-compaction-history-p)
                            (lambda (_id) t)))
                   (harness-ui-compaction-ask-panel-string
                    "s1" (harness-ui-compaction-ask-test--record))))
         (lines (harness-ui-compaction-ask-test--lines string)))
    (should (string-match-p "\\` .*Context nearly full  ~84\\.0k of 100k tokens · Demo scripted\\'"
                            (nth 0 lines)))
    (should (equal "   Carry on  $0.315 uncached against $0.025 cached" (nth 1 lines)))
    (should (equal "" (nth 2 lines)))
    (should (equal "   Choose what goes first" (nth 3 lines)))
    (should (equal '("    b  Brief summary    ~$0.0040          narrative, tool calls in brief · read uncached · first and last messages kept"
                     "    s  Summary          ~$0.330           whole conversation · read uncached · first and last messages kept · default"
                     "    t  Transcript file  free              whole conversation as a file the model reads"
                     "    f  Start afresh     free              nothing carried over"
                     "    x  Cut old context  free              oldest messages dropped · newest kept as they are"
                     "    c  Carry on         ~$0.315 uncached  whole conversation again, uncached"
                     "    q  Not now                            message waits")
                   (seq-subseq lines 4 11)))
    (should (equal "" (nth 11 lines)))
    ;; No capitals line: nothing here is answered "always".
    (should (equal "   Left out: searchable with session_history" (nth 12 lines)))
    (should (equal "   from the box: C-c . b" (nth 13 lines)))
    ;; A session without the session_history tool says nothing about it.
    (should-not (string-match-p
                 "session_history"
                 (harness-ui-compaction-ask-panel-string
                  "s1" (harness-ui-compaction-ask-test--record))))
    ;; Nothing is a sentence: no line ends in a full stop.
    (should-not (cl-some (lambda (l) (string-match-p "[.!?]\\'" l)) lines))
    ;; Every character belongs to the panel, amber.
    (should (equal "p1" (get-text-property 0 'harness-ui-compaction-ask-panel string)))
    (should (equal "p1" (get-text-property 0 'harness-ui-carry-panel string)))
    (should (memq 'harness-ui-carry-face (ensure-list (get-text-property 0 'face string))))
    ;; A choice's button says more when hovered.
    (let* ((at (string-search "Brief summary" string))
           (help (get-text-property at 'help-echo string)))
      (should (string-prefix-p "Brief summary (~$0.0040) · narrative, tool calls in brief" help))
      (should (string-suffix-p " · Press b on this panel, or click" help)))))

(ert-deftest harness-ui-compaction-ask-panel-is-only-for-its-own-question ()
  "The panel stands in for the ordinary one only for the question that
asks what goes first before an automatic compaction."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (should (harness-ui-compaction-ask--info (harness-ui-compaction-ask-test--record)))
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
      (harness-call 'session/usage-add sid '(:input 10 :output 10 :cache-read 3000 :context 7500))
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
          (should (string-match-p "Context nearly full" text))
          (should (string-match-p "Choose what goes first" text))
          (should (string-match-p "Transcript file  free" text)))
        ;; The ordinary question panel is not drawn as well.
        (should-not (string-search "Answer \"always\" with a choice"
                                   (buffer-substring-no-properties (point-min) (point-max))))
        (should (harness-ui-compaction-ask-waiting-p sid))
        ;; t, with point on the panel.
        (let ((at (harness-ui-compaction-ask-test--panel buffer)))
          (call-interactively (lookup-key (get-text-property at 'keymap) "t"))))
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
