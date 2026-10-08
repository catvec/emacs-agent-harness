;;; harness-ui-cowboy-test.el --- Tests for the cold-cache question panel  -*- lexical-binding: t; -*-

;;; Commentary:

;; The panel the chat draws for the harness's question about a cold
;; prompt cache (harness-ui-cowboy.el): what it says, what its keys
;; answer, that it stands in for the ordinary question panel only for
;; that question, and, end to end against the state layer, the demo
;; provider and the in-process ACP connection, that a message sent from
;; the compose box of a cold session waits on it, the cache panel
;; giving way, and goes once a key answers it.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)
(require 'harness-ui-cowboy)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-compaction--running)
(defvar harness-compaction-brief-model)
(defvar harness-tools-agent--questions)
(defvar harness-cowboy--asking)
(defvar harness-cowboy-default)
(defvar harness-cowboy-ask)
(defvar harness-cowboy-min-context)
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

(defun harness-ui-cowboy-test--record (&rest overrides)
  "Return a cold-cache question record as the UI keeps it, with OVERRIDES.
Its `:cowboy' is as it comes over the wire: names for symbols, vectors
for lists."
  (harness-plist-merge
   (list :id "p1" :kind "question" :session-id "s1"
         :question "Your message waits: this session's prompt cache lapsed …"
         :options ["Brief summary (~$0.0040, the default)" "Summary (~$0.330)" "Transcript file (free)"
                   "Start afresh (free)" "Carry on (~$0.315 uncached)" "Not now"]
         :allow-free-text t
         :cowboy (list :at 1000.0 :ttl 300 :expires 1300.0 :model "demo:scripted" :model-label "Demo scripted"
                       :context 84000 :messages 12 :carry-on 0.315 :carry-on-cached 0.025
                       :preview "now add tests for the parser" :default "brief" :history t
                       :choices
                       (vector
                        '(:choice "brief" :label "Brief summary" :what "a cheap model summarises the first and last messages"
                                  :cost 0.004 :cost-text "~$0.0040" :by "Demo cheap" :after 900)
                        '(:choice "summary" :label "Summary" :what "the session's model summarises it all, reading it uncached"
                                  :cost 0.33 :cost-text "~$0.330" :by "Demo scripted" :after 1500)
                        '(:choice "transcript" :label "Transcript file" :what "the conversation goes to a file the model reads as it needs"
                                  :cost 0.0 :cost-text "free" :after 200)
                        '(:choice "fresh" :label "Start afresh" :what "nothing is carried over; the model looks back when it needs to"
                                  :cost 0.0 :cost-text "free" :after 90)
                        '(:choice "carry-on" :label "Carry on" :what "the whole conversation goes again, uncached"
                                  :cost 0.315 :cost-text "~$0.315 uncached")
                        '(:choice "hold" :label "Not now" :what "the message waits; nothing is sent yet"))))
   overrides))

(defun harness-ui-cowboy-test--lines (string)
  "Return the lines of STRING without its properties, trailing blanks trimmed."
  (mapcar (lambda (l) (string-trim-right l)) (split-string (substring-no-properties string) "\n")))

(ert-deftest harness-ui-cowboy-panel-says-what-each-choice-costs ()
  "The panel says when the cache lapsed and for what, which message waits,
what carrying on costs against the cache it lost, and a row per choice:
its key, its button, its cost and what it does, the default marked."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (let* ((string (harness-ui-cowboy-panel-string "s1" (harness-ui-cowboy-test--record) 1400.0))
         (lines (harness-ui-cowboy-test--lines string)))
    (should (string-match-p (format "\\` .*Prompt cache cold  since %s · Demo scripted · ~84\\.0k tokens\\'"
                                    (regexp-quote (format-time-string "%H:%M" 1300.0)))
                            (nth 0 lines)))
    (should (equal "   Your message waits: “now add tests for the parser”" (nth 1 lines)))
    (should (equal (concat "   Carrying on sends the whole conversation again, uncached: about $0.315 instead of"
                           " the $0.025 it would cost cached.  What goes first?")
                   (nth 2 lines)))
    (should (equal "" (nth 3 lines)))
    (should (equal '("    b  Brief summary    ~$0.0040          a cheap model summarises the first and last messages · the default"
                     "    s  Summary          ~$0.330           the session's model summarises it all, reading it uncached"
                     "    t  Transcript file  free              the conversation goes to a file the model reads as it needs"
                     "    f  Start afresh     free              nothing is carried over; the model looks back when it needs to"
                     "    c  Carry on         ~$0.315 uncached  the whole conversation goes again, uncached"
                     "    q  Not now                            the message waits; nothing is sent yet")
                   (seq-subseq lines 4 10)))
    (should (equal "" (nth 10 lines)))
    (should (equal "    B   S   T   F   C  the same, from now on without asking" (nth 11 lines)))
    (should (equal (concat "   Whichever you choose, the model can search and read the conversation it leaves out"
                           " (session_history).")
                   (nth 12 lines)))
    (should (equal "   or type a choice below: “transcript”, “always brief”" (nth 13 lines)))
    ;; Every character belongs to the panel, amber.
    (should (equal "p1" (get-text-property 0 'harness-ui-cowboy-panel string)))
    (should (equal "p1" (get-text-property (1- (length string)) 'harness-ui-cowboy-panel string)))
    (should (memq 'harness-ui-cowboy-face (ensure-list (get-text-property 0 'face string))))
    ;; A row that wraps is indented in amber too.
    (let ((prefix (get-text-property (string-search "a cheap model" string) 'wrap-prefix string)))
      (should (string-blank-p prefix))
      (should (eq 'harness-ui-cowboy-face (get-text-property 0 'face prefix))))
    ;; A choice's button says more when hovered.
    (let* ((at (string-search "Brief summary" string))
           (help (get-text-property at 'help-echo string)))
      (should (string-match-p "\\`Brief summary (~\\$0\\.0040): a cheap model summarises the first and last messages\\." help))
      (should (string-match-p "Written by Demo cheap\\." help))
      (should (string-match-p "The conversation then holds ~900 tokens\\." help))
      (should (string-match-p "Press b on this panel, or click; B makes it the default\\." help))
      (should (string-match-p "The default, taken when nobody is asked\\." help)))))

(ert-deftest harness-ui-cowboy-panel-for-another-sender-and-sparse-info ()
  "A message another session sent says so; a question that brings less
falls back to the choices' own words, with no costs."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (let* ((r (harness-ui-cowboy-test--record
             :cowboy (list :expires 1300.0 :from '(:kind "session" :id "abc12345" :name "Reviewer")
                           :preview "please look at this" :history :false :default "transcript")))
         (lines (harness-ui-cowboy-test--lines (harness-ui-cowboy-panel-string "s1" r 1400.0))))
    (should (equal "   A message from session “Reviewer” waits: “please look at this”" (nth 1 lines)))
    (should (equal "   Carrying on sends the whole conversation again, uncached.  What goes first?" (nth 2 lines)))
    (should (member "    t  Transcript file  the conversation goes to a file the model reads as it needs · the default"
                    lines))
    (should-not (cl-some (lambda (l) (string-match-p "session_history" l)) lines))))

(ert-deftest harness-ui-cowboy-keys-answer ()
  "A choice's key answers with it, its capital always; q holds; the
digits of any question are there too."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (let ((answers nil)
        (map (harness-ui-cowboy--keymap "s1" "p1")))
    (cl-letf (((symbol-function 'harness-ui-pending-answer-question)
               (lambda (sid pid answer &rest _) (push (list sid pid answer) answers))))
      (dolist (key '("b" "s" "t" "f" "c" "q" "T" "B" "F"))
        (call-interactively (lookup-key map key)))
      (should (equal '(("s1" "p1" "brief") ("s1" "p1" "summary") ("s1" "p1" "transcript") ("s1" "p1" "fresh")
                       ("s1" "p1" "carry-on") ("s1" "p1" "hold")
                       ("s1" "p1" "always transcript") ("s1" "p1" "always brief") ("s1" "p1" "always fresh"))
                     (reverse answers))))
    ;; No "always" for not now.
    (should-not (lookup-key map "Q"))
    (should (keymapp (keymap-parent map)))
    (should (eq (keymap-parent map) harness-ui-pending-question-map))))

(ert-deftest harness-ui-cowboy-only-for-its-question ()
  "An ordinary question keeps the ordinary panel."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (with-temp-buffer
    (should-not (harness-ui-cowboy--insert-panel (list :id "p2" :kind "question" :question "Which colour?"
                                                       :options ["red" "green"])))
    (should-not (harness-ui-cowboy--insert-panel (list :id "p3" :kind "permission" :cowboy '(:expires 1.0))))
    (should (equal "" (buffer-string)))))

;;;; End to end

(defun harness-ui-cowboy-test--script (request)
  "Answer REQUEST: a summary when it asks for one, else a short reply."
  (if (string-match-p "handoff summary" (or (plist-get request :system) ""))
      '((:type text :delta "SUMMARY TEXT") (:type usage :input 50 :output 5) (:type done :stop-reason end-turn))
    '((:type text :delta "Done.") (:type usage :input 30 :output 5 :cache-read 400 :context 430)
      (:type done :stop-reason end-turn))))

(defmacro harness-ui-cowboy-test-with (&rest body)
  "Load the state layer with cowboy, then the chat with its panels; run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent compaction
                    tools-agent tools-sessions cowboy acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-compaction--running)
     (clrhash harness-tools-agent--questions)
     (clrhash harness-cowboy--asking)
     (setq harness-acp--clients nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override #'harness-ui-cowboy-test--script)
           (harness-compaction-brief-model "demo:scripted")
           (harness-cowboy-default 'brief)
           (harness-cowboy-ask t)
           (harness-cowboy-min-context 0)
           (harness-non-interactive nil)
           (harness-naming-auto nil)
           (harness-acp-token nil)
           (harness-ui-default-position 'full)
           (harness-cache-ttl-overrides nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (dolist (m '(ui ui-compose ui-markdown ui-pending ui-chat ui-cache ui-cowboy))
         (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (unwind-protect
           (progn ,@body)
         (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) harness-chat--buffers)
         (clrhash harness-chat--buffers)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-cowboy-test--panel (buffer)
  "Return where BUFFER's cold-cache panel starts, or nil."
  (with-current-buffer buffer
    (text-property-not-all (point-min) (point-max) 'harness-ui-cowboy-panel nil)))

(defun harness-ui-cowboy-test--cache-panel-p (buffer)
  "Non-nil when BUFFER shows the cache panel."
  (with-current-buffer buffer
    (text-property-any (point-min) (point-max) 'harness-ui-cache-panel t)))

(ert-deftest harness-ui-cowboy-chat-asks-and-a-key-answers ()
  "A message sent from the compose box of a session whose cache lapsed
waits on the panel, the cache panel giving way; t answers it, the
transcript compaction goes first, the message after it, and the panel
goes."
  (harness-ui-cowboy-test-with
    (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id))
           (buffer nil))
      (harness-call 'session/append sid '(:kind user :content "please refactor the parser"))
      (harness-call 'session/append sid '(:kind assistant :content "Done: parser.el rewritten"))
      (harness-call 'session/usage-add sid '(:input 10 :output 10 :cache-read 3000 :context 3020 :cache-at 1000.0))
      (setq buffer (harness-chat-buffer sid))
      (set-window-buffer (selected-window) buffer)
      (harness-test-wait (lambda () (with-current-buffer buffer (and (not harness-chat--loading) harness-compose-end)))
                         5 "the session to load")
      ;; Cold, and nothing sent yet: the cache panel says so.
      (harness-test-wait (lambda () (harness-ui-cowboy-test--cache-panel-p buffer)) 5 "the cache panel")
      (with-current-buffer buffer
        (goto-char harness-compose-end)
        (insert "now add tests")
        (harness-chat-send))
      (harness-test-wait (lambda () (harness-ui-cowboy-test--panel buffer)) 5 "the cold-cache panel")
      (harness-test-wait (lambda () (not (harness-ui-cowboy-test--cache-panel-p buffer))) 5 "the cache panel to go")
      (with-current-buffer buffer
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (should (string-match-p "Prompt cache cold" text))
          (should (string-match-p "Your message waits: “now add tests”" text))
          (should (string-match-p " t  Transcript file  free" text)))
        ;; The ordinary question panel is not drawn as well.
        (should-not (string-search "What goes first?  Answer \"always\""
                                   (buffer-substring-no-properties (point-min) (point-max))))
        (should (harness-ui-cowboy-waiting-p sid))
        ;; t, with point on the panel.
        (let ((at (harness-ui-cowboy-test--panel buffer)))
          (call-interactively (lookup-key (get-text-property at 'keymap) "t"))))
      (harness-test-wait (lambda () (and (not (harness-call 'agent/running sid))
                                         (eq 'idle (plist-get (harness-call 'session/get sid) :status))
                                         (cl-find 'assistant (harness-call 'session/nodes sid)
                                                  :key (lambda (n) (plist-get n :kind)) :from-end t)
                                         (equal "Done." (plist-get (car (last (harness-call 'session/nodes sid))) :content))))
                         10 "the turn to end")
      (should (equal "transcript" (harness-node-compaction-kind
                                   (cl-find 'compaction (harness-call 'session/nodes sid) :key (lambda (n) (plist-get n :kind))))))
      (harness-test-wait (lambda () (not (harness-ui-cowboy-test--panel buffer))) 5 "the panel to go")
      (harness-test-wait (lambda () (with-current-buffer buffer
                                      (string-match-p "context compacted into a transcript file, the prompt cache being cold"
                                                      (buffer-substring-no-properties (point-min) (point-max)))))
                         5 "the compaction in the chat")
      (should-not (harness-ui-cowboy-waiting-p sid)))))

(provide 'harness-ui-cowboy-test)
;;; harness-ui-cowboy-test.el ends here
