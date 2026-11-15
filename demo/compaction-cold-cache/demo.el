;;; demo.el --- What a compaction answers, and what still asks  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; A batch demonstration of the cold-cache rule after a compaction: the
;; real gate (`harness-cowboy--settled-p'), the real panel
;; (`harness-ui-cache--state') and the real record (`session/get') run
;; against real sessions, and what each says is printed.  No model is
;; called: the demo provider is scripted, and the only thing it is asked
;; for is a turn's end.
;;
;;   demo/compaction-cold-cache/demo.sh
;;
;; The cases are the ones the change is about:
;;
;;   1. The compaction's own result goes cold: no question, no panel.
;;   2. Its cache lapses again a turn later: still no question, still no
;;      panel, and still one compaction.
;;   3. The conversation grows back past what the compaction replaced: a
;;      question, and the panel, are real again.
;;   4. A compaction that failed settles nothing.
;;   5. A compaction that was reverted settles nothing.
;;
;; It also prints the cost of a record read, which is why the answer is
;; carried on the record rather than derived from the transcript.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-sessions)
(defvar harness-agent--turns)
(defvar harness-compaction--running)
(defvar harness-tools-question--questions)
(defvar harness-cowboy--asking)
(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-cowboy-default)
(defvar harness-cowboy-ask)
(defvar harness-cowboy-min-context)
(defvar harness-cowboy-new-conversation-limit)
(defvar harness-non-interactive)
(defvar harness-compaction-brief-model)
(defvar harness-ui--models)

(defun demo--script (request)
  "Answer REQUEST as the demo model: a summary when asked, else a turn's end."
  (if (string-match-p "handoff summary" (or (plist-get request :system) ""))
      '((:type text :delta "SUMMARY TEXT") (:type usage :input 50 :output 5)
        (:type done :stop-reason end-turn))
    '((:type text :delta "Done.")
      (:type usage :input 30 :output 5 :cache-read 400 :context 430)
      (:type done :stop-reason end-turn))))

(defun demo--say (fmt &rest args)
  "Print FMT with ARGS as one line of the demo's output."
  (princ (concat (apply #'format fmt args) "\n")))

(defun demo--compactions (sid)
  "Return the compaction nodes of SID."
  (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'compaction))
                    (harness-call 'session/nodes sid)))

(defun demo--session ()
  "Make a session with a conversation worth compacting; return its id."
  (let ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                      :model "demo:scripted") :id)))
    (harness-call 'session/append sid '(:kind user :content "please refactor the parser"))
    (harness-call 'session/append sid '(:kind assistant :content "Done: parser.el rewritten"))
    (harness-call 'session/usage-add sid '(:input 10 :output 10 :cache-read 3000
                                                 :context 3020 :cache-at 1000.0 :cache-ttl 300))
    sid))

(defun demo--lapse (sid)
  "Give SID the cold cache of a conversation 430 tokens big, at 1000.0."
  (harness-call 'session/usage-add sid '(:input 10 :output 10 :cache-read 400
                                               :context 430 :cache-at 1000.0 :cache-ttl 300)))

(defun demo--asked (sid)
  "Return what a message to SID would be asked, as the gate decides it."
  (let ((session (harness-call 'session/get sid)))
    (cond ((harness-cowboy--settled-p session) "nothing (a compaction settled it)")
          ((not (harness-cowboy-cold-p session)) "nothing (the cache is warm)")
          (t "the cold-cache question"))))

(defun demo--panel (sid)
  "Return what SID's cache panel would draw, as the UI decides it."
  (let* ((session (harness-call 'session/get sid))
         (state (harness-ui-cache--state session (float-time))))
    (if state
        (format "yes, headed \"Cache  %s\""
                (harness-ui-cache--detail state (float-time)))
      "no panel")))

(defun demo--record (sid)
  "Return what SID's record says settled its conversation, in words."
  (let ((made (plist-get (harness-call 'session/get sid) :compaction)))
    (if made
        (format "%s, which replaced %d tokens"
                (plist-get made :kind) (plist-get made :replaced))
      "none")))

(defun demo--show (sid label)
  "Print what SID does for a message now, under LABEL."
  (demo--say "  %-30s asked: %s" label (demo--asked sid))
  (demo--say "  %-30s panel: %s" "" (demo--panel sid))
  (demo--say "  %-30s record: %s" "" (demo--record sid))
  (demo--say "  %-30s compactions: %d" "" (length (demo--compactions sid))))

(defun demo--prompt (sid text)
  "Send TEXT to SID and wait for the turn to end."
  (harness-test-await (harness-call 'agent/prompt sid text) 20))

(defmacro demo--with (&rest body)
  "Run BODY in a harness of the demo modules and a scripted provider."
  (declare (indent 0) (debug t))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent compaction
                  tools-question tools-sessions cowboy ui ui-cache))
       (harness-test-load-module m))
     (clrhash harness-sessions) (clrhash harness-agent--turns)
     (clrhash harness-compaction--running) (clrhash harness-tools-question--questions)
     (clrhash harness-cowboy--asking)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override #'demo--script)
           (harness-compaction-brief-model "demo:scripted")
           (harness-cowboy-default 'transcript) (harness-cowboy-ask t)
           (harness-cowboy-min-context 0) (harness-cowboy-new-conversation-limit 100000)
           (harness-non-interactive nil)
           (harness-ui--models (make-hash-table :test 'equal)))
       ,@body)))

(defun demo--cost ()
  "Print what a record read costs with a compaction in force."
  (let ((sid (demo--session)))
    (dotimes (i 2000)
      (harness-call 'session/append sid (list :kind (if (cl-evenp i) 'user 'assistant)
                                              :content (format "message %d of the conversation" i))))
    (harness-test-await (harness-call 'compaction/compact sid '(:kind "transcript" :idle t)) 20)
    (let* ((s (harness-session--get sid))
           (start (float-time)))
      (dotimes (_ 20) (harness-session-plist s))
      (demo--say "  %d nodes, %.2f ms a record read" (length (harness-session--path s))
                 (* 1000 (/ (- (float-time) start) 20))))))

(defun demo-run ()
  "Print what a compaction answers, and what still asks."
  (demo--with
    (demo--say "1. A compaction's own result goes cold")
    (let ((sid (demo--session)))
      (harness-test-await (harness-call 'compaction/compact sid '(:kind "transcript" :idle t)) 20)
      (demo--lapse sid)
      (demo--show sid "after the compaction"))

    (demo--say "")
    (demo--say "2. Its cache lapses again, a turn later")
    (let ((sid (demo--session)))
      (harness-test-await (harness-call 'compaction/compact sid '(:kind "transcript" :idle t)) 20)
      (demo--lapse sid)
      (demo--prompt sid "and the lexer")
      (demo--lapse sid)
      (demo--show sid "after another cold turn"))

    (demo--say "")
    (demo--say "3. The conversation grows back past what was replaced (3020 tokens)")
    (let ((sid (demo--session)))
      (harness-test-await (harness-call 'compaction/compact sid '(:kind "transcript" :idle t)) 20)
      (harness-call 'session/usage-add sid '(:input 10 :output 10 :cache-read 400
                                                   :context 3600 :cache-at 1000.0 :cache-ttl 300))
      (demo--show sid "grown back"))

    (demo--say "")
    (demo--say "4. A compaction that failed")
    (let ((sid (demo--session)))
      (cl-letf (((symbol-function 'harness-method/session/write-transcript)
                 (lambda (&rest _) (signal 'harness-error (list "no room for a transcript")))))
        (ignore-errors (harness-test-await
                        (harness-call 'compaction/compact sid '(:kind "transcript" :idle t)) 20)))
      (demo--show sid "after the failure"))

    (demo--say "")
    (demo--say "5. A compaction that was reverted")
    (let ((sid (demo--session)))
      (harness-test-await (harness-call 'compaction/compact sid '(:kind "transcript" :idle t)) 20)
      (harness-call 'compaction/revert sid)
      (demo--lapse sid)
      (demo--show sid "after the revert"))

    (demo--say "")
    (demo--say "6. What a record read costs")
    (demo--cost)))

(provide 'demo)
;;; demo.el ends here
