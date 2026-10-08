;;; harness-ui-compact-test.el --- Tests for compacting a conversation by hand  -*- lexical-binding: t; -*-

;;; Commentary:

;; `harness-compact' and /compact: what each kind of compaction is said
;; to cost, the question that offers them, and compacting from a chat's
;; message box against the real state layer, the demo provider and the
;; in-process ACP connection.  The chat shows what kind each compaction
;; was.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)
(require 'harness-ui-compact)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui--sessions)
(defvar harness-ui-default-position)
(defvar harness-chat--loading)
(defvar harness-chat--buffers)
(defvar harness-chat-commands)
(defvar harness-compose-end)
(defvar harness-compose--skills)
(defvar harness-compose-commands)
(defvar harness-compaction--running)
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-chat-send "harness-ui-chat")
(declare-function harness-chat--command "harness-ui-chat")
(declare-function harness-chat--clear-compose "harness-ui-chat")
(declare-function harness-compose-text "harness-ui-compose")
(declare-function harness-compose-completion-at-point "harness-ui-compose")
(declare-function harness-acp--drop-client "harness-acp")

;;;; What each kind costs, and the question

(defconst harness-ui-compact-test--estimate
  '(:context 84500 :model "test:big" :model-label "Big" :cached nil
    :carry-on 0.4225 :carry-on-cached 0.0169 :compacting nil :kind "summary"
    :kinds ((:kind "summary" :model "test:big" :model-label "Big" :input 84541 :output 2000
                   :cached nil :cost 0.462705 :after 2000)
            (:kind "brief" :model "test:small" :model-label "Small" :input 725 :output 2000
                   :cached nil :cost 0.01090625 :after 2000)
            (:kind "transcript" :model nil :model-label nil :input 0 :output 0
                   :cached nil :cost 0.0 :after 84 :file-tokens 84500)))
  "A `compaction/estimate' answer as it comes over ACP: kinds are strings.")

(ert-deftest harness-ui-compact-says-what-each-kind-costs ()
  "Each kind says what it costs, short, at list prices: a brief summary
and a summary their estimate, a transcript nothing.  A model the
catalogue does not price gives no cost.  The descriptions say who reads
what, the costs going beside them."
  (let ((e harness-ui-compact-test--estimate))
    (should (equal "~$0.011" (harness-ui-compact-cost-text e 'brief)))
    (should (equal "~$0.463" (harness-ui-compact-cost-text e 'summary)))
    (should (equal "free" (harness-ui-compact-cost-text e 'transcript)))
    (should (equal "free" (harness-ui-compact-cost-text nil 'transcript)))
    (should-not (harness-ui-compact-cost-text nil 'brief))
    (let ((unpriced (list :kinds (list (list :kind "brief" :model "x:y" :cost nil)))))
      (should-not (harness-ui-compact-cost-text unpriced 'brief)))
    (should (equal "Brief summary" (harness-ui-compact-label 'brief)))
    (should (equal "Transcript file" (harness-ui-compact-label 'transcript)))
    (should (equal (concat "Small reads only the first and last messages, ~725 tokens in all."
                           "  Most of the middle is left out, which the summary says.")
                   (harness-ui-compact-describe e 'brief)))
    (should (equal "Big reads the whole conversation again, ~84.5k tokens uncached."
                   (harness-ui-compact-describe e 'summary)))
    ;; A summary on a fork of a warm hosted conversation reads it from the cache.
    (let ((warm (list :context 84500
                      :kinds (list (list :kind "summary" :model-label "Big" :input 84541 :cached t :cost 0.1)))))
      (should (string-suffix-p "~84.5k tokens mostly from the cache." (harness-ui-compact-describe warm 'summary))))
    (should (string-match-p "\\`The whole conversation goes to a file .* note of ~84 tokens .*No model is asked anything\\.\\'"
                            (harness-ui-compact-describe e 'transcript)))
    (should (equal "the next message sends ~84.5k tokens uncached, about $0.422"
                   (harness-ui-compact-carry-on-text e)))
    (should (equal "the next message sends ~84.5k tokens from the prompt cache"
                   (harness-ui-compact-carry-on-text '(:context 84500 :cached t))))))

(ert-deftest harness-ui-compact-asks-with-the-costs ()
  "The question offers each kind with its cost, the cheap one first, and
cancel; the help it shows first is a table of who writes what for how
much, and what carrying on costs."
  (let (asked)
    (cl-letf (((symbol-function 'read-multiple-choice)
               (lambda (prompt choices &optional help show-help &rest _)
                 (setq asked (list prompt choices help show-help))
                 (assq ?b choices))))
      (should (eq 'brief (harness-ui-compact-read '(:id "s1" :name "Parser work")
                                                  harness-ui-compact-test--estimate))))
    (pcase-let ((`(,prompt ,choices ,help ,show-help) asked))
      (should (equal "Compact the conversation" prompt))
      (should (equal '((?b "brief summary (~$0.011)") (?s "summary (~$0.463)")
                       (?t "transcript file (free)") (?q "cancel"))
                     (mapcar (lambda (c) (list (car c) (cadr c))) choices)))
      (should (equal "*Harness compaction*" show-help))
      (should (string-match-p "Session +“Parser work”" help))
      (should (string-match-p "Model +Big" help))
      (should (string-match-p "Carry on +the next message sends ~84\\.5k tokens uncached, about \\$0\\.422" help))
      (should (string-match-p "^  b +brief summary +Small +~\\$0\\.011 +Small reads only" help))
      (should (string-match-p "^  s +summary +Big +~\\$0\\.463 +Big reads the whole" help))
      (should (string-match-p "^  t +transcript file +- +free +The whole conversation" help)))
    (cl-letf (((symbol-function 'read-multiple-choice) (lambda (_p choices &rest _) (assq ?q choices))))
      (should-not (harness-ui-compact-read '(:id "s1") harness-ui-compact-test--estimate)))))

(ert-deftest harness-ui-compact-kind-from-words ()
  "/compact takes a kind by name or by its key; nothing asks."
  (should-not (harness-ui-compact-parse-kind ""))
  (should-not (harness-ui-compact-parse-kind "  "))
  (should (eq 'brief (harness-ui-compact-parse-kind "brief")))
  (should (eq 'brief (harness-ui-compact-parse-kind "b")))
  (should (eq 'summary (harness-ui-compact-parse-kind " summary ")))
  (should (eq 'transcript (harness-ui-compact-parse-kind "t")))
  (should-error (harness-ui-compact-parse-kind "sideways") :type 'user-error))

(ert-deftest harness-ui-compact-says-what-it-did ()
  "The outcome names the kind, how much it compacted, and the file or
the model."
  (should (equal "Compacted ~84.5k tokens into /tmp/p/.harness/transcripts/t.md"
                 (harness-ui-compact-outcome
                  '(:kind "compaction"
                    :meta (:compaction "transcript" :file "/tmp/p/.harness/transcripts/t.md" :input-tokens 84500)))))
  (should (equal (format "Compacted ~84.5k tokens into a brief summary by %s" (harness-ui-model-label "demo:scripted"))
                 (harness-ui-compact-outcome
                  '(:kind "compaction" :meta (:compaction "brief" :model "demo:scripted" :input-tokens 84500)))))
  (should (equal "Compacted ~2.0k tokens into a summary"
                 (harness-ui-compact-outcome '(:kind "compaction" :meta (:compaction "summary" :input-tokens 2000)))))
  (should (equal "Compacted the conversation into a summary"
                 (harness-ui-compact-outcome '(:kind "compaction" :meta nil)))))

(ert-deftest harness-ui-compact-waits-for-the-turn ()
  "A session running a turn, or blocked inside one, is not compacted."
  (let ((harness-ui--sessions (make-hash-table :test 'equal)))
    (dolist (status '("running" "blocked" running))
      (puthash "s1" (list :id "s1" :status status) harness-ui--sessions)
      (should-error (harness-compact "s1" 'transcript) :type 'user-error))))

;;;; In a chat

(defconst harness-ui-compact-test--summary
  '((:type text :delta "BRIEF SUMMARY") (:type done :stop-reason end-turn))
  "The summary the demo provider writes.")

(defmacro harness-ui-compact-test-with (&rest body)
  "Load the state layer with compaction, the demo provider and the chat, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent compaction acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-compaction--running)
     (setq harness-acp--clients nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override harness-ui-compact-test--summary)
           (harness-naming-auto nil)
           (harness-acp-token nil)
           (harness-ui-default-position 'full)
           (default-directory dir))
       (dolist (m '(ui ui-compose ui-markdown ui-chat ui-compact))
         (harness-test-load-module m))
       (clrhash harness-ui--sessions)
       (unwind-protect
           (progn ,@body)
         (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) harness-chat--buffers)
         (clrhash harness-chat--buffers)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-compact-test--session ()
  "Create a demo session with a conversation of twenty messages; return its id."
  (let ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted"
                                      :name "Compact test")
                        :id)))
    (dotimes (i 20)
      (harness-call 'session/append sid (list :kind (if (cl-evenp i) 'user 'assistant)
                                              :content (format "message %d about the parser" i))))
    sid))

(defun harness-ui-compact-test--open (sid)
  "Open SID's chat buffer and wait for it to load."
  (let ((buffer (harness-chat-buffer sid)))
    (harness-test-wait (lambda () (with-current-buffer buffer
                                    (and (not harness-chat--loading) harness-compose-end)))
                       5 "the session to load")
    buffer))

(defun harness-ui-compact-test--compactions (sid)
  "Return the compaction nodes of SID, oldest first."
  (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'compaction)) (harness-call 'session/nodes sid)))

(defun harness-ui-compact-test--send (buffer text)
  "Type TEXT in BUFFER's message box and send it."
  (with-current-buffer buffer
    (goto-char harness-compose-end)
    (insert text)
    (harness-chat-send)))

(defun harness-ui-compact-test--shows (buffer text)
  "Non-nil when BUFFER shows TEXT."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((case-fold-search nil)) (search-forward text nil t)))))

(ert-deftest harness-ui-compact-slash-command ()
  "/compact KIND in a chat's message box compacts its session rather than
sending a message: no turn runs, the box empties, and the chat shows
what kind of compaction it was.  /compact alone asks, with the costs."
  (harness-ui-compact-test-with
    (let* ((sid (harness-ui-compact-test--session))
           (buffer (harness-ui-compact-test--open sid))
           (visited nil))
      ;; A transcript file: no request, a note pointing at the file.
      (harness-ui-compact-test--send buffer "/compact transcript")
      (harness-test-wait (lambda () (harness-ui-compact-test--compactions sid)) 5 "the compaction")
      (with-current-buffer buffer (should (equal "" (harness-compose-text))))
      (let* ((node (car (harness-ui-compact-test--compactions sid)))
             (file (plist-get (plist-get node :meta) :file)))
        (should (equal "transcript" (harness-node-compaction-kind node)))
        (should (file-exists-p file))
        ;; No turn ran: the session has the ten replies it had.
        (should (= 10 (cl-count 'assistant (harness-call 'session/nodes sid)
                                :key (lambda (n) (plist-get n :kind)))))
        (should (member (plist-get (plist-get (harness-call 'session/get sid) :usage) :turns) '(nil 0)))
        (harness-test-wait (lambda () (harness-ui-compact-test--shows buffer "context compacted into a transcript file"))
                           5 "the compaction in the chat")
        ;; Its header opens the file.
        (let ((action (with-current-buffer buffer
                        (get-text-property (- (harness-ui-compact-test--shows buffer "[open the transcript]") 2)
                                           'harness-chat-action))))
          (cl-letf (((symbol-function 'find-file-other-window) (lambda (f &rest _) (setq visited f))))
            (funcall action))
          (should (equal file visited))))
      ;; Asked: the estimate's costs, and a brief summary chosen.
      (let (choices)
        (cl-letf (((symbol-function 'read-multiple-choice)
                   (lambda (_prompt offered &rest _) (setq choices offered) (assq ?b offered))))
          (harness-ui-compact-test--send buffer "/compact")
          (harness-test-wait (lambda () (= 2 (length (harness-ui-compact-test--compactions sid)))) 10
                             "the brief summary"))
        (should (equal '(?b ?s ?t ?q) (mapcar #'car choices)))
        ;; The demo model is priced: both summaries say what they cost.
        (should (string-match-p "\\`brief summary (~\\$[0-9.]+)\\'" (cadr (assq ?b choices))))
        (should (string-match-p "\\`summary (~\\$[0-9.]+)\\'" (cadr (assq ?s choices))))
        (should (equal "transcript file (free)" (cadr (assq ?t choices)))))
      (let ((node (cadr (harness-ui-compact-test--compactions sid))))
        (should (equal "brief" (harness-node-compaction-kind node)))
        (should (string-prefix-p "BRIEF SUMMARY\n\nHarness note:" (plist-get node :content))))
      (harness-test-wait (lambda () (harness-ui-compact-test--shows
                                     buffer (format "context compacted into a brief summary by %s"
                                                    (harness-ui-model-label "demo:scripted"))))
                         5 "the brief summary in the chat")
      (with-current-buffer buffer (should (equal "" (harness-compose-text))))
      ;; A kind that is none keeps the box as typed.
      (with-current-buffer buffer
        (goto-char harness-compose-end)
        (insert "/compact sideways")
        (should-error (harness-chat-send) :type 'user-error)
        (should (equal "/compact sideways" (harness-compose-text)))
        (harness-chat--clear-compose)))))

(ert-deftest harness-ui-compact-slash-command-is-the-whole-message ()
  "Only a message that is /compact, maybe with a word after it, is the
command: a longer message, another word starting the same, or a skill
called compact goes to the session as usual.  / completion offers it."
  (harness-ui-compact-test-with
    (let* ((sid (harness-ui-compact-test--session))
           (buffer (harness-ui-compact-test--open sid)))
      (with-current-buffer buffer
        (should (equal (cons #'harness-ui-compact--chat-command "")
                       (harness-chat--command "/compact")))
        (should (equal (cons #'harness-ui-compact--chat-command "brief")
                       (harness-chat--command "/compact  brief")))
        (should-not (harness-chat--command "/compactness"))
        (should-not (harness-chat--command "please /compact"))
        (should-not (harness-chat--command "/compact\nand then fix the parser"))
        (should-not (harness-chat--command "/nothing"))
        ;; / completion at the start of the box offers it.
        (should (member "compact" harness-compose-commands))
        (goto-char harness-compose-end)
        (insert "/comp")
        (should (member "compact" (all-completions "comp" (nth 2 (harness-compose-completion-at-point)))))
        (harness-chat--clear-compose)
        ;; A skill of that name wins.
        (let ((harness-compose--skills '("compact")))
          (should-not (harness-chat--command "/compact")))))))

(provide 'harness-ui-compact-test)
;;; harness-ui-compact-test.el ends here
