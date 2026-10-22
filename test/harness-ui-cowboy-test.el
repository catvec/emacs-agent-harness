;;; harness-ui-cowboy-test.el --- Tests for the cold-cache question panel  -*- lexical-binding: t; -*-

;;; Commentary:

;; The panel the chat draws for the harness's question about a cold
;; prompt cache (harness-ui-cowboy.el): what it says, what its keys
;; answer, that it stands in for the ordinary question panel only for
;; that question, and, end to end against the state layer, the demo
;; provider and the in-process ACP connection, that a message sent from
;; the compose box of a cold session waits on it, the cache panel
;; giving way, and goes once a key answers it.  A cache a redaction
;; dropped is headed so and compared with no cached price, in a panel
;; made from a record and, against a fake hosted loop (Claude Code,
;; Copilot), from the question the harness asks; the words for a lapsed
;; cache and for a cache of another model stay as they were.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)
(require 'harness-ui-cowboy)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-providers)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-compaction--running)
(defvar harness-compaction-brief-model)
(defvar harness-tools-question--questions)
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
(declare-function harness-cowboy-cold-p "harness-cowboy" (session &optional now))
(declare-function harness-define-provider "harness-provider")
(declare-function harness-provider--forget "harness-provider" (id))

;;;; The panel, from a record

(defun harness-ui-cowboy-test--record (&rest overrides)
  "Return a cold-cache question record as the UI keeps it, with OVERRIDES.
Its `:cowboy' is as it comes over the wire: names for symbols, vectors
for lists."
  (harness-plist-merge
   (list :id "p1" :kind "question" :session-id "s1"
         :question "Your message waits: this session's prompt cache lapsed …"
         :options ["Brief summary (~$0.0040, the default)" "Summary (~$0.330)" "Transcript file (free)"
                   "Start afresh (free)" "Carry on (~$0.315 uncached)" "Ignore (~$0.315 uncached)" "Not now"]
         :allow-free-text t
         :cowboy (list :at 1000.0 :ttl 300 :expires 1300.0 :model "demo:scripted" :model-label "Demo scripted"
                       :context 84000 :messages 12 :carry-on 0.315 :carry-on-cached 0.025
                       :preview "now add tests for the parser" :default "brief" :history t
                       :choices
                       (vector
                        '(:choice "brief" :label "Brief summary" :what "a cheap model summarises the narrative, tool calls in brief"
                                  :cost 0.004 :cost-text "~$0.0040" :by "Demo cheap" :after 900)
                        '(:choice "summary" :label "Summary" :what "the session's model summarises it all, reading it uncached"
                                  :cost 0.33 :cost-text "~$0.330" :by "Demo scripted" :after 1500)
                        '(:choice "transcript" :label "Transcript file" :what "the conversation goes to a file the model reads as it needs"
                                  :cost 0.0 :cost-text "free" :after 200)
                        '(:choice "fresh" :label "Start afresh" :what "nothing is carried over; the model looks back when it needs to"
                                  :cost 0.0 :cost-text "free" :after 90)
                        '(:choice "carry-on" :label "Carry on" :what "the whole conversation goes again, uncached"
                                  :cost 0.315 :cost-text "~$0.315 uncached")
                        '(:choice "ignore" :label "Ignore" :what "send the whole context as it is, adding nothing"
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
    (should (equal '("    b  Brief summary    ~$0.0040          a cheap model summarises the narrative, tool calls in brief · the default"
                     "    s  Summary          ~$0.330           the session's model summarises it all, reading it uncached"
                     "    t  Transcript file  free              the conversation goes to a file the model reads as it needs"
                     "    f  Start afresh     free              nothing is carried over; the model looks back when it needs to"
                     "    c  Carry on         ~$0.315 uncached  the whole conversation goes again, uncached"
                     "    i  Ignore           ~$0.315 uncached  send the whole context as it is, adding nothing"
                     "    q  Not now                            the message waits; nothing is sent yet")
                   (seq-subseq lines 4 11)))
    (should (equal "" (nth 11 lines)))
    (should (equal "    B   S   T   F   C   I  the same, in every session from now on, without asking" (nth 12 lines)))
    (should (equal (concat "   Whichever you choose, the model can search and read the conversation it leaves out"
                           " (session_history).")
                   (nth 13 lines)))
    (should (equal "   or type a choice below: “transcript”, “always brief”" (nth 14 lines)))
    ;; The keys type in the compose box: the last line says how to press one from there.
    (should (equal "   from the box: C-c . b" (nth 15 lines)))
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
      (should (string-match-p "\\`Brief summary (~\\$0\\.0040): a cheap model summarises the narrative, tool calls in brief\\." help))
      (should (string-match-p "Written by Demo cheap\\." help))
      (should (string-match-p "The conversation then holds ~900 tokens\\." help))
      (should (string-match-p "Press b on this panel, or click; B makes it the default of every session, taken without asking\\." help))
      (should (string-match-p "The default, taken when nobody is asked\\." help)))))

(ert-deftest harness-ui-cowboy-panel-heads-a-cache-held-for-another-model ()
  "A cache held for a model the session no longer uses is headed so, in
place of the clock time it lapsed at, which is not why it is asked about."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (let* ((cowboy (plist-put (copy-sequence (plist-get (harness-ui-cowboy-test--record) :cowboy))
                            :cache-model-label "Claude Opus 5.5"))
         (lines (harness-ui-cowboy-test--lines
                 (harness-ui-cowboy-panel-string "s1" (harness-ui-cowboy-test--record :cowboy cowboy) 1400.0))))
    (should (string-match-p "\\` .*Prompt cache cold  held for Claude Opus 5\\.5, not Demo scripted · ~84\\.0k tokens\\'"
                            (nth 0 lines)))))

(ert-deftest harness-ui-cowboy-panel-heads-a-cache-a-redaction-dropped ()
  "A cache a redaction dropped is headed with the moment of the drop, in
place of the clock time it would have lapsed at, and says it was a
redaction.  The line under the waiting message compares the price of
carrying on with no cached price, as none can be had; everything else is
the panel of a lapsed cache, the choices and their prices included."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (let* ((lapsed (harness-ui-cowboy-panel-string "s1" (harness-ui-cowboy-test--record) 1400.0))
         (cowboy (plist-put (plist-put (copy-sequence (plist-get (harness-ui-cowboy-test--record) :cowboy))
                                       :expires 1100.0)
                            :dropped 1100.0))
         (dropped (harness-ui-cowboy-panel-string "s1" (harness-ui-cowboy-test--record :cowboy cowboy) 1400.0))
         (lines (harness-ui-cowboy-test--lines dropped))
         (lapsed-lines (harness-ui-cowboy-test--lines lapsed)))
    (should (string-match-p (format "\\` .*Prompt cache cold  dropped by a redaction at %s · Demo scripted · ~84\\.0k tokens\\'"
                                    (regexp-quote (format-time-string "%H:%M" 1100.0)))
                            (nth 0 lines)))
    (should-not (string-match-p "since" (nth 0 lines)))
    (should (equal "   Your message waits: “now add tests for the parser”" (nth 1 lines)))
    ;; No "about $0.315 instead of the $0.025 it would cost cached": the cached price is not to be had.
    (should (equal "   Carrying on sends the whole conversation again, uncached.  What goes first?" (nth 2 lines)))
    (should-not (string-match-p "instead of\\|cost cached" dropped))
    ;; The rest is the panel of a lapsed cache, the price of carrying on on its row.
    (should (equal (seq-subseq lapsed-lines 3) (seq-subseq lines 3)))
    (should (member "    c  Carry on         ~$0.315 uncached  the whole conversation goes again, uncached" lines))
    (should (member "    i  Ignore           ~$0.315 uncached  send the whole context as it is, adding nothing" lines))
    (should (equal "p1" (get-text-property (1- (length dropped)) 'harness-ui-cowboy-panel dropped)))
    ;; Drawn on a later day, the time says its day.
    (should (string-match-p "dropped by a redaction at [A-Z][a-z]+ [0-9]+, [0-9:]+ ·"
                            (nth 0 (harness-ui-cowboy-test--lines
                                    (harness-ui-cowboy-panel-string "s1" (harness-ui-cowboy-test--record :cowboy cowboy)
                                                                    (+ 1100.0 (* 3 86400)))))))))

(ert-deftest harness-ui-cowboy-panel-keeps-the-words-of-the-other-caches ()
  "A cache that lapsed by itself, one held for another model, and a `:dropped'
that is no moment are told in the words they always were, the cached
price compared included: only a drop of a cache the session's own model
holds is told as one.  A cache dropped and held for another model reads
as the other model's, as the new model has none of it either way."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (let* ((cowboy (plist-get (harness-ui-cowboy-test--record) :cowboy))
         (compare (concat "   Carrying on sends the whole conversation again, uncached: about $0.315 instead of"
                          " the $0.025 it would cost cached.  What goes first?"))
         (lines (lambda (info)
                  (harness-ui-cowboy-test--lines
                   (harness-ui-cowboy-panel-string "s1" (harness-ui-cowboy-test--record :cowboy info) 1400.0))))
         (since (format "\\` .*Prompt cache cold  since %s · Demo scripted · ~84\\.0k tokens\\'"
                        (regexp-quote (format-time-string "%H:%M" 1300.0)))))
    ;; A lapsed cache, with the drop absent (an old harness), nil, or as the wire says nil.
    (dolist (info (list cowboy
                        (plist-put (copy-sequence cowboy) :dropped nil)
                        (plist-put (copy-sequence cowboy) :dropped :null)
                        (plist-put (copy-sequence cowboy) :dropped :false)))
      (let ((got (funcall lines info)))
        (should (string-match-p since (nth 0 got)))
        (should (equal compare (nth 2 got)))))
    ;; Held for another model, whether or not the redaction dropped it as well.
    (dolist (info (list (plist-put (copy-sequence cowboy) :cache-model-label "Claude Opus 5.5")
                        (plist-put (plist-put (copy-sequence cowboy) :cache-model-label "Claude Opus 5.5")
                                   :dropped 1100.0)))
      (let ((got (funcall lines info)))
        (should (string-match-p "\\` .*Prompt cache cold  held for Claude Opus 5\\.5, not Demo scripted · ~84\\.0k tokens\\'"
                                (nth 0 got)))
        (should (equal compare (nth 2 got)))))))

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

(ert-deftest harness-ui-cowboy-panel-is-a-panel-of-the-compose-box ()
  "The panel is one of the compose box, where its keys type.
C-c . and a key press it from there (`harness-compose-panel-key'): all of
the panel is named by the request, and the keys the panel binds are the
ones that find a command on it, a capital's included."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (with-temp-buffer
    (let ((harness-ui-session-id "s1"))
      (should (harness-ui-cowboy--insert-panel (harness-ui-cowboy-test--record))))
    (should (cl-loop for i from (point-min) below (point-max)
                     always (equal "p1" (get-text-property i 'harness-compose-panel))))
    (dolist (key '("b" "s" "t" "f" "c" "i" "q" "B" "T" "3"))
      (should (commandp (harness-compose--panel-command key (point-min)))))
    ;; Q, like any key it has no command for, is no key of the panel.
    (should-not (harness-compose--panel-command "Q" (point-min)))
    (should-not (harness-compose--panel-command "x" (point-min)))))

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
                    tools-question tools-sessions cowboy acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-compaction--running)
     (clrhash harness-tools-question--questions)
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

(ert-deftest harness-ui-cowboy-chat-i-ignores-the-cold-cache ()
  "i on the panel ignores the cold cache: the message goes with the whole
conversation, no compaction runs and no note is added to the chat."
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
      (with-current-buffer buffer
        (goto-char harness-compose-end)
        (insert "now add tests")
        (harness-chat-send))
      (harness-test-wait (lambda () (harness-ui-cowboy-test--panel buffer)) 5 "the cold-cache panel")
      (with-current-buffer buffer
        ;; i, with point on the panel.
        (let ((at (harness-ui-cowboy-test--panel buffer)))
          (call-interactively (lookup-key (get-text-property at 'keymap) "i"))))
      (harness-test-wait (lambda () (and (not (harness-call 'agent/running sid))
                                         (eq 'idle (plist-get (harness-call 'session/get sid) :status))
                                         (equal "Done." (plist-get (car (last (harness-call 'session/nodes sid))) :content))))
                         10 "the turn to end")
      (should-not (cl-find 'compaction (harness-call 'session/nodes sid)
                           :key (lambda (n) (plist-get n :kind))))
      (should-not (cl-some (lambda (n) (and (eq (plist-get n :kind) 'hint)
                                            (string-match-p "Prompt cache cold" (plist-get n :content))))
                           (harness-call 'session/nodes sid)))
      (should (member "now add tests"
                      (mapcar (lambda (n) (plist-get n :content)) (harness-call 'session/nodes sid))))
      (harness-test-wait (lambda () (not (harness-ui-cowboy-test--panel buffer))) 5 "the panel to go")
      (should-not (harness-ui-cowboy-waiting-p sid)))))

(defun harness-ui-cowboy-test--define-hosted ()
  "Define `hosted', a fake hosted loop (Claude Code, Copilot).
It keeps the conversation itself and answers every request with a
conversation state, a reply and usage that wrote 400 tokens of cache."
  (harness-define-provider 'hosted
    :label "Hosted"
    :models (lambda ()
              (harness-resolved
               (list (list :name "m" :label "Hosted M" :context-window 200000
                           :pricing '(:input 4.0 :output 20.0 :cache-read 0.4 :cache-write 5.0)))))
    :complete (lambda (req)
                (let ((on-event (plist-get req :on-event)))
                  (run-at-time 0.005 nil
                               (lambda ()
                                 (funcall on-event '(:type provider-state :state (:conv "c1")))
                                 (funcall on-event '(:type text :delta "ok"))
                                 (funcall on-event '(:type usage :input 30 :output 5
                                                           :cache-write 400 :context 430))
                                 (funcall on-event '(:type done :stop-reason end-turn)))))
                (list :cancel #'ignore))
    :capabilities '(:hosted-loop t :resume t :fork t)))

(ert-deftest harness-ui-cowboy-chat-asks-after-a-redaction-dropped-the-cache ()
  "A message to a hosted session whose provider conversation a redaction
dropped waits on the panel, though the clock of its cache has minutes to
run.  The panel says a redaction dropped the cache, and when, and
compares no cached price; carrying on answers it, the message goes in
the new conversation, whose first request writes a cache of its own."
  (harness-ui-cowboy-test-with
    (harness-ui-cowboy-test--define-hosted)
    (unwind-protect
        (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "hosted:m") :id))
               (buffer nil))
          (harness-call 'session/append sid '(:kind user :content "please refactor the parser"))
          (harness-call 'session/append sid '(:kind assistant :content "Done: parser.el rewritten"))
          ;; The last request read 3000 tokens of cache, just now: warm for five minutes.
          (harness-call 'session/usage-add sid (list :input 10 :output 10 :cache-read 3000 :context 3020
                                                     :cache-at (float-time)))
          (should-not (harness-cowboy-cold-p (harness-call 'session/get sid)))
          (setq buffer (harness-chat-buffer sid))
          (set-window-buffer (selected-window) buffer)
          (harness-test-wait (lambda () (with-current-buffer buffer (and (not harness-chat--loading) harness-compose-end)))
                             5 "the session to load")
          (should-not (harness-ui-cowboy-test--cache-panel-p buffer))
          ;; The redaction drops the provider conversation, and its cache with it.
          (should (equal '(:checkpoints 0 :cache-dropped t) (harness-call 'session/reset-provider sid)))
          (harness-test-wait (lambda () (harness-ui-cowboy-test--cache-panel-p buffer)) 5 "the cache panel")
          (with-current-buffer buffer
            (goto-char harness-compose-end)
            (insert "now add tests")
            (harness-chat-send))
          (harness-test-wait (lambda () (harness-ui-cowboy-test--panel buffer)) 5 "the cold-cache panel")
          (harness-test-wait (lambda () (not (harness-ui-cowboy-test--cache-panel-p buffer))) 5 "the cache panel to go")
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p (concat "Prompt cache cold  dropped by a redaction at [0-9:]+"
                                              " · Hosted M · ~3\\.0k tokens\n")
                                      text))
              (should (string-match-p "Your message waits: “now add tests”" text))
              (should (string-match-p
                       "Carrying on sends the whole conversation again, uncached\\.  What goes first\\?\n" text))
              (should-not (string-match-p "instead of the\\|since [0-9]" text))
              (should (string-match-p " c  Carry on  +~\\$[0-9.]+ uncached" text)))
            ;; c, with point on the panel.
            (let ((at (harness-ui-cowboy-test--panel buffer)))
              (call-interactively (lookup-key (get-text-property at 'keymap) "c"))))
          (harness-test-wait (lambda () (and (not (harness-call 'agent/running sid))
                                             (eq 'idle (plist-get (harness-call 'session/get sid) :status))
                                             (equal "ok" (plist-get (car (last (harness-call 'session/nodes sid)))
                                                                    :content))))
                             10 "the turn to end")
          (harness-test-wait (lambda () (not (harness-ui-cowboy-test--panel buffer))) 5 "the panel to go")
          ;; The session's own pending list, as the UI last heard it, lags the
          ;; answer by a push (`harness-acp--session-debounce'): until it comes
          ;; the question still reads as waiting.
          (harness-test-wait (lambda () (not (harness-ui-cowboy-waiting-p sid))) 5
                             "the question to leave the session's pending list")
          (should-not (harness-ui-cowboy-waiting-p sid))
          ;; The new conversation's first request wrote a cache of its own: nothing is dropped any more.
          (let ((cache (plist-get (harness-call 'session/get sid) :cache)))
            (should cache)
            (should-not (plist-get cache :dropped))))
      (remhash 'hosted harness-providers)
      (harness-provider--forget 'hosted))))

(provide 'harness-ui-cowboy-test)
;;; harness-ui-cowboy-test.el ends here
