;;; harness-cache-compact-test.el --- Tests for compacting just before the prompt cache lapses  -*- lexical-binding: t; -*-

;;; Commentary:

;; A conversation whose prompt cache is about to lapse, and whose user is
;; gone, is compacted as the user saved for a cold cache, where a message
;; that met the cold cache would not be asked about
;; (harness-cache-compact.el).  The demo provider writes the summaries;
;; the sessions stand on it, with a cache stamped just now (it lasts 300
;; seconds, so the watcher's own event does not come in the middle of a
;; test: the tests send it themselves).  The context is 3020 tokens and
;; the smallest that is compacted is set to 1000, unless a test is about
;; that.  Asking is off, unless a test is about that.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-sessions)
(defvar harness-agent--turns)
(defvar harness-providers)
(defvar harness-compaction--running)
(defvar harness-compaction-brief-model)
(defvar harness-tools-question--questions)
(defvar harness-cowboy--asking)
(defvar harness-cowboy-default)
(defvar harness-cowboy-ask)
(defvar harness-cowboy-min-context)
(defvar harness-non-interactive)
(defvar harness-decisions--entries)
(defvar harness-cache-precompact)
(defvar harness-cache-precompact-min-context)
(defvar harness-cache-compact--running)
(defvar harness-cache-warm)
(defvar harness-cache-warm--refreshing)
(defvar harness-cache--watched)
(defvar harness-cache--fired)
(defvar harness-cache--claims)
(defvar harness-cache--presence)
(defvar harness-cache--announced)
(defvar harness-cache--ends)
(defvar harness-cache-ttl)
(defvar harness-cache-ttl-overrides)
(declare-function harness-cowboy--remember "harness-cowboy" (choice &optional session-id))
(declare-function harness-provider--forget "harness-provider" (id))

(defvar harness-cache-compact-test--requests nil
  "The requests the demo provider answered that were not summaries, newest first.")

(defvar harness-cache-compact-test--compacted nil
  "The `cache/compacted' events heard, oldest first: (SESSION-ID KIND NODE).")

(defvar harness-cache-compact-test--fail nil
  "Non-nil makes the demo provider fail a summary.")

(defun harness-cache-compact-test--script (request)
  "Answer REQUEST: a summary when it asks for one, else a short reply."
  (if (string-match-p "handoff summary" (or (plist-get request :system) ""))
      (if harness-cache-compact-test--fail
          '((:type done :stop-reason error :error "the summariser is down"))
        '((:type text :delta "SUMMARY TEXT")
          (:type usage :input 50 :output 5)
          (:type done :stop-reason end-turn)))
    (push request harness-cache-compact-test--requests)
    '((:type text :delta "Done.")
      (:type usage :input 30 :output 5 :cache-read 400 :context 430)
      (:type done :stop-reason end-turn))))

(defmacro harness-cache-compact-test-with (&rest body)
  "Load the modules, the demo provider and the decisions; run BODY.
Compacting before the lapse is on, the saved option is the default one
\(a brief summary) and nobody is asked about it, and a conversation of
1000 tokens is big enough."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent compaction
                  tools-question tools-sessions decisions cowboy cache cache-compact))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-compaction--running)
     (clrhash harness-tools-question--questions)
     (clrhash harness-cowboy--asking)
     (clrhash harness-cache-compact--running)
     (dolist (table (list harness-cache--watched harness-cache--fired harness-cache--claims
                          harness-cache--presence harness-cache--announced harness-cache--ends))
       (clrhash table))
     (setq harness-decisions--entries nil
           harness-cache-compact-test--requests nil
           harness-cache-compact-test--compacted nil
           harness-cache-compact-test--fail nil)
     (harness-on 'cache/compacted
                 (lambda (sid kind node)
                   (setq harness-cache-compact-test--compacted
                         (append harness-cache-compact-test--compacted (list (list sid kind node))))))
     (unwind-protect
         (let ((harness-provider-demo--delay 0.005)
               (harness-provider-demo-script-override #'harness-cache-compact-test--script)
               (harness-compaction-brief-model "demo:scripted")
               (harness-cowboy-default 'brief)
               (harness-cowboy-ask nil)
               (harness-cowboy-min-context 0)
               (harness-non-interactive nil)
               (harness-cache-precompact t)
               (harness-cache-precompact-min-context 1000)
               (harness-cache-ttl 300)
               (harness-cache-ttl-overrides nil)
               (default-directory dir))
           (harness-add-filter 'permission/decide
                               (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
           ,@body)
       (maphash (lambda (_ entry) (when (timerp (plist-get entry :timer)) (cancel-timer (plist-get entry :timer))))
                harness-cache--watched)
       (maphash (lambda (_ timer) (cancel-timer timer)) harness-cache--ends))))

(defun harness-cache-compact-test-session (&rest plist)
  "Create a demo session with an answered exchange and a cache stamped just now.
PLIST goes to `session/create'.  Its context is 3020 tokens."
  (let ((sid (plist-get (apply #'harness-call 'session/create :cwd (harness-test-temp-dir)
                               (if (plist-member plist :model) plist (append plist '(:model "demo:scripted"))))
                        :id)))
    (harness-call 'session/append sid '(:kind user :content "please refactor the parser"))
    (harness-call 'session/append sid '(:kind assistant :content "Done: parser.el rewritten"))
    (harness-call 'session/usage-add sid (list :input 10 :output 10 :cache-read 3000 :context 3020
                                               :cache-at (float-time) :cache-ttl 300))
    sid))

(defun harness-cache-compact-test--event (sid &rest overrides)
  "Emit `cache/pre-expire' for session SID, with INFO as OVERRIDES change it."
  (let* ((session (harness-call 'session/get sid))
         (cache (plist-get session :cache)))
    (harness-emit 'cache/pre-expire sid
                  (harness-plist-merge
                   (list :expires (plist-get cache :expires) :ttl 300 :lead 10.0
                         :at (plist-get cache :at) :model (plist-get cache :model)
                         :context (plist-get (plist-get session :usage) :context)
                         :status 'idle :running nil)
                   overrides))))

(defun harness-cache-compact-test--wait ()
  "Wait until no compaction before a lapse is under way."
  (harness-test-wait (lambda () (zerop (hash-table-count harness-cache-compact--running))) 6
                     "the compaction to end"))

(defun harness-cache-compact-test--compactions (sid)
  "Return the compaction nodes in session SID's transcript."
  (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'compaction)) (harness-call 'session/nodes sid)))

(defun harness-cache-compact-test--notes (sid)
  "Return the notes of compactions made before a lapse in session SID."
  (cl-remove-if-not (lambda (n) (and (eq (plist-get n :kind) 'hint)
                                     (string-prefix-p "Prompt cache about to lapse" (or (plist-get n :content) ""))))
                    (harness-call 'session/nodes sid)))

(defun harness-cache-compact-test--hints (sid)
  "Return the texts of the hints in session SID's transcript."
  (delq nil (mapcar (lambda (n) (and (eq (plist-get n :kind) 'hint) (plist-get n :content)))
                    (harness-call 'session/nodes sid))))

(defun harness-cache-compact-test--compacts-p (sid &rest overrides)
  "Non-nil when the event, as OVERRIDES change it, has session SID compacted.
The module claims the cache when it acts; it is then waited for."
  (let ((before (length (harness-cache-compact-test--compactions sid))))
    (apply #'harness-cache-compact-test--event sid overrides)
    (when (eq 'compact (harness-call 'cache/claimed sid))
      (harness-cache-compact-test--wait))
    (> (length (harness-cache-compact-test--compactions sid)) before)))

;;;; Compacting

(ert-deftest harness-cache-compact-compacts-as-the-user-saved-when-they-are-gone ()
  "With the user gone, the conversation is compacted before its cache lapses
as the default for a cold cache says -- a brief summary -- the node says it
was made before the lapse, the conversation starts over from it, and a note
tells of it, in a lasting decision's words."
  (harness-cache-compact-test-with
    (let ((sid (harness-cache-compact-test-session)))
      (harness-cache-compact-test--event sid)
      (should (eq 'compact (harness-call 'cache/claimed sid)))
      (harness-cache-compact-test--wait)
      (let ((nodes (harness-cache-compact-test--compactions sid)))
        (should (= 1 (length nodes)))
        (let ((meta (plist-get (car nodes) :meta)))
          (should (equal "brief" (plist-get meta :compaction)))
          (should (equal "brief" (plist-get (plist-get meta :precompact) :choice)))
          (should (numberp (plist-get (plist-get meta :precompact) :expires)))))
      ;; The conversation started over: no cache, so nothing to warn of.
      (should-not (plist-get (harness-call 'session/get sid) :cache))
      ;; The note.
      (let* ((notes (harness-cache-compact-test--notes sid))
             (note (car notes)))
        (should (= 1 (length notes)))
        (should (string-match-p "\\`Prompt cache about to lapse at [0-9][0-9]:[0-9][0-9]: compacted into a brief summary, while it was still cached, so the next message sends that instead of ~3\\.0k tokens uncached\\'"
                                (plist-get note :content)))
        (let* ((id (harness-node-decision note))
               (decision (harness-call 'decision/get id)))
          (should id)
          (should-not (harness-node-decided-by note))
          (should (eq 'precompact (plist-get decision :kind)))
          (should (eq 'done (plist-get decision :state)))
          (should (equal "Compacting a conversation just before its prompt cache lapses, while it is still cached"
                         (plist-get decision :text)))
          (should (equal (plist-get note :id) (plist-get decision :node)))
          (should (equal sid (plist-get decision :session)))))
      ;; Heard of.
      (should (equal 1 (length harness-cache-compact-test--compacted)))
      (should (equal (list sid 'brief) (seq-take (car harness-cache-compact-test--compacted) 2))))))

(ert-deftest harness-cache-compact-follows-an-always-answer ()
  "A user who is asked what goes first has nothing compacted before the lapse;
once an \"always\" answer saved a choice, the compaction is of its kind and the
note follows from its decision too, with that decision's own undo and redo:
the choice of what goes first can be changed from the note."
  (harness-cache-compact-test-with
    (let* ((harness-cowboy-ask t)
           (first (harness-cache-compact-test-session))
           (asked (harness-cache-compact-test-session)))
      (should-not (harness-cache-compact-test--compacts-p asked))
      (let ((always (progn (harness-cowboy--remember 'fresh first)
                           (plist-get (harness-call 'cowboy/default) :decision)))
            (sid (harness-cache-compact-test-session)))
        (should always)
        (should (eq 'fresh (plist-get (harness-call 'cowboy/default) :choice)))
        (should-not harness-cowboy-ask)
        (harness-cache-compact-test--event sid)
        (harness-cache-compact-test--wait)
        (let ((node (car (harness-cache-compact-test--compactions sid)))
              (note (car (harness-cache-compact-test--notes sid))))
          (should (equal "fresh" (plist-get (plist-get node :meta) :compaction)))
          (should (equal "started afresh" (and (string-match "lapse at [0-9:]+: \\([a-z ]+\\)," (plist-get note :content))
                                               (match-string 1 (plist-get note :content)))))
          (should (equal always (harness-node-decided-by note)))
          (should (harness-node-decision note))
          (should-not (equal always (harness-node-decision note)))
          (should (eq 'cowboy (plist-get (harness-call 'decision/get always) :kind)))
          (should (eq 'precompact (plist-get (harness-call 'decision/get (harness-node-decision note)) :kind))))))))

(ert-deftest harness-cache-compact-does-what-the-user-saved-or-nothing ()
  "A user who saved \"carry on\" or \"ignore\" for a cold cache has nothing compacted:
the conversation goes on as it is.  Every kind that compacts is made."
  (harness-cache-compact-test-with
    (dolist (choice '(carry-on ignore))
      (let ((harness-cowboy-default choice)
            (sid (harness-cache-compact-test-session)))
        (should-not (harness-cache-compact-test--compacts-p sid))
        (should-not (harness-call 'cache/claimed sid))
        (should-not (harness-cache-compact-test--notes sid))))
    (dolist (choice '(brief summary transcript fresh))
      (let ((harness-cowboy-default choice)
            (sid (harness-cache-compact-test-session)))
        (should (harness-cache-compact-test--compacts-p sid))
        (should (equal (symbol-name choice)
                       (plist-get (plist-get (car (harness-cache-compact-test--compactions sid)) :meta)
                                  :compaction)))))))

(ert-deftest harness-cache-compact-needs-a-saved-option-to-follow ()
  "Without the cowboy module there is no saved option for a cold cache, and
nothing is compacted: what the user would choose is not known."
  (harness-cache-compact-test-with
    (harness-unregister-method 'cowboy/default)
    (let ((sid (harness-cache-compact-test-session)))
      (should-not (harness-cache-compact-test--compacts-p sid))
      (should-not (harness-call 'cache/claimed sid))
      (should-not (harness-cache-compact-test--notes sid)))))

(ert-deftest harness-cache-compact-leaves-alone-a-session-whose-user-would-be-asked ()
  "Where a message that met the cold cache would be asked about -- asking is on
and the session waits for the user -- the compaction is theirs to choose: the
question is not taken from them, and the cache is left unclaimed.  It is
compacted where nobody would be asked: asking off (what an \"always\" answer
does), or a session that never waits for the user."
  (harness-cache-compact-test-with
    (let ((harness-cowboy-ask t)
          (waits (harness-cache-compact-test-session))
          (never (harness-cache-compact-test-session :non-interactive t)))
      (should-not (harness-cache-compact-test--compacts-p waits))
      (should-not (harness-call 'cache/claimed waits))
      (should-not (harness-cache-compact-test--notes waits))
      ;; The same conversation, with a user who is not asked.
      (should (harness-cache-compact-test--compacts-p never))
      (should (= 1 (length (harness-cache-compact-test--notes never))))
      (should (equal (list never 'brief) (seq-take (car harness-cache-compact-test--compacted) 2)))
      (let ((harness-cowboy-ask nil))
        (should (harness-cache-compact-test--compacts-p waits))
        (should (= 1 (length (harness-cache-compact-test--notes waits))))))))

;;;; When not

(ert-deftest harness-cache-compact-leaves-a-conversation-alone-when-it-should ()
  "Not while the user is around, nor when something else claimed the cache,
nor with the feature off, a turn running, the session not idle, the
session a seed, a compaction under way, work going on outside its turn, or
the conversation too small."
  (harness-cache-compact-test-with
    (let ((sid (harness-cache-compact-test-session)))
      ;; The user is around.
      (harness-call 'cache/active sid)
      (should-not (harness-cache-compact-test--compacts-p sid))
      (harness-call 'cache/active sid 0)
      (cl-letf (((symbol-function 'harness-cache-around-p) (lambda (&rest _) nil)))
        ;; Claimed by the handler that reads the cache again.
        (harness-call 'cache/claim sid 'warm)
        (should-not (harness-cache-compact-test--compacts-p sid))
        (should (eq 'warm (harness-call 'cache/claimed sid)))
        (remhash sid harness-cache--claims)
        ;; Off.
        (let ((harness-cache-precompact nil))
          (should-not (harness-cache-compact-test--compacts-p sid)))
        ;; A turn runs, or the session is not idle.
        (should-not (harness-cache-compact-test--compacts-p sid :running t))
        (harness-call 'session/set-status sid 'blocked)
        (should-not (harness-cache-compact-test--compacts-p sid))
        (harness-call 'session/set-status sid 'idle)
        ;; A compaction under way.
        (puthash sid (harness-make-promise) harness-cache-compact--running)
        (should-not (harness-cache-compact-test--compacts-p sid))
        (remhash sid harness-cache-compact--running)
        ;; Work outside its turn.
        (let ((outstanding (lambda (_text id) (and (equal id sid) "a worker runs"))))
          (harness-add-filter 'agent/outstanding outstanding 50)
          (unwind-protect
              (should-not (harness-cache-compact-test--compacts-p sid))
            (harness-remove-filter 'agent/outstanding outstanding)))
        ;; None of it: it does.
        (should (harness-cache-compact-test--compacts-p sid))))))

(ert-deftest harness-cache-compact-leaves-a-seed-alone ()
  "The context of a seed is shared with the sessions forked from it: it is not
compacted, whatever else holds."
  (harness-cache-compact-test-with
    (let ((sid (harness-cache-compact-test-session)))
      (harness-call 'session/set-ext sid :seed t)
      (cl-letf (((symbol-function 'harness-cache-around-p) (lambda (&rest _) nil)))
        (should-not (harness-cache-compact-test--compacts-p sid))))))

(ert-deftest harness-cache-compact-leaves-a-small-conversation-alone ()
  "Under the smallest context, and under the cowboy's smallest, nothing is
compacted: it costs little to send, and a summary of it loses detail."
  (harness-cache-compact-test-with
    (cl-letf (((symbol-function 'harness-cache-around-p) (lambda (&rest _) nil)))
      (let ((sid (harness-cache-compact-test-session)))
        (let ((harness-cache-precompact-min-context 3021))
          (should-not (harness-cache-compact-test--compacts-p sid)))
        (let ((harness-cowboy-min-context 5000))
          (should-not (harness-cache-compact-test--compacts-p sid)))
        ;; The context at the smallest is compacted.
        (let ((harness-cache-precompact-min-context 3020))
          (should (harness-cache-compact-test--compacts-p sid)))))))

;;;; Turning it off and on

(ert-deftest harness-cache-compact-note-turns-it-off-and-on ()
  "The note's decision is a switch: undone, the feature is off and nothing is
compacted before a lapse; redone, it is on again.  Every note in every
session shares it."
  (harness-cache-compact-test-with
    (cl-letf (((symbol-function 'harness-cache-around-p) (lambda (&rest _) nil)))
      (let* ((one (harness-cache-compact-test-session))
             (two (harness-cache-compact-test-session)))
        (should (harness-cache-compact-test--compacts-p one))
        (should (harness-cache-compact-test--compacts-p two))
        (let ((a (harness-node-decision (car (harness-cache-compact-test--notes one))))
              (b (harness-node-decision (car (harness-cache-compact-test--notes two)))))
          (should (equal a b))
          (should (= 1 (length (harness-call 'decision/list :kind 'precompact))))
          ;; Off.
          (let ((r (harness-call 'decision/undo a)))
            (should (eq 'undone (plist-get r :outcome)))
            (should (equal "Undone: conversations are no longer compacted just before their prompt cache lapses"
                           (plist-get r :message))))
          (should-not harness-cache-precompact)
          (let ((three (harness-cache-compact-test-session)))
            (should-not (harness-cache-compact-test--compacts-p three))
            ;; On again.
            (let ((r (harness-call 'decision/redo a)))
              (should (eq 'done (plist-get r :outcome)))
              (should (equal "Redone: conversations are compacted just before their prompt cache lapses again"
                             (plist-get r :message))))
            (should harness-cache-precompact)
            (should (harness-cache-compact-test--compacts-p three))
            (should (equal a (harness-node-decision (car (harness-cache-compact-test--notes three)))))))))))

(ert-deftest harness-cache-compact-a-setting-changed-by-hand-ends-the-switch ()
  "A setting that was changed since is left as it is, and the switch says so."
  (harness-cache-compact-test-with
    (cl-letf (((symbol-function 'harness-cache-around-p) (lambda (&rest _) nil)))
      (let* ((sid (harness-cache-compact-test-session)))
        (should (harness-cache-compact-test--compacts-p sid))
        (let ((id (harness-node-decision (car (harness-cache-compact-test--notes sid)))))
          ;; Turned off in Settings: undo has nothing to take back.
          (setq harness-cache-precompact nil)
          (let ((r (harness-call 'decision/undo id)))
            (should (eq 'changed (plist-get r :outcome)))
            (should (string-match-p "turned off since" (plist-get r :message))))
          (should-not harness-cache-precompact))))
    (harness-cache-compact-test-with
      (cl-letf (((symbol-function 'harness-cache-around-p) (lambda (&rest _) nil)))
        (let* ((sid (harness-cache-compact-test-session)))
          (should (harness-cache-compact-test--compacts-p sid))
          (let ((id (harness-node-decision (car (harness-cache-compact-test--notes sid)))))
            (harness-call 'decision/undo id)
            ;; Turned on in Settings: redo has nothing to put back.
            (setq harness-cache-precompact t)
            (let ((r (harness-call 'decision/redo id)))
              (should (eq 'changed (plist-get r :outcome)))
              (should (string-match-p "on again already" (plist-get r :message))))
            (should harness-cache-precompact)))))))

;;;; Around a message

(ert-deftest harness-cache-compact-holds-a-message-until-the-compaction-is-done ()
  "A message that comes while the compaction runs waits for it, and is sent the
compacted conversation.  It shows as a queued message while it waits, and
is gone from the list of those that wait once it is recorded."
  (harness-cache-compact-test-with
    (let ((harness-provider-demo--delay 0.3)
          (sid (harness-cache-compact-test-session)))
      (cl-letf (((symbol-function 'harness-cache-around-p) (lambda (&rest _) nil)))
        (harness-cache-compact-test--event sid))
      (should (gethash sid harness-cache-compact--running))
      (let ((turn (harness-call 'agent/prompt sid "and now the lexer")))
        (should-not (harness-cache-compact-test--compactions sid))
        (harness-test-wait (lambda () (plist-get (harness-call 'session/get sid) :steering)) 5
                           "the message to show as waiting")
        (let ((items (plist-get (harness-call 'session/get sid) :steering)))
          (should (equal '("and now the lexer") (mapcar (lambda (item) (plist-get item :text)) items)))
          (should (equal "the compaction" (plist-get (car items) :why))))
        (harness-test-await turn 15)
        (should-not (plist-get (harness-call 'session/get sid) :steering)))
      (let ((request (car harness-cache-compact-test--requests)))
        (should request)
        (should (string-match-p "SUMMARY TEXT"
                                (mapconcat (lambda (m) (mapconcat (lambda (b) (or (plist-get b :text) ""))
                                                                  (plist-get m :content) "\n"))
                                           (plist-get request :messages) "\n"))))
      (should (= 1 (length (harness-cache-compact-test--compactions sid)))))))

(ert-deftest harness-cache-compact-leaves-the-conversation-when-the-summary-fails ()
  "A summary that cannot be made leaves the conversation as it was: no note, no
compaction, and nothing left running."
  (harness-cache-compact-test-with
    (setq harness-cache-compact-test--fail t)
    (cl-letf (((symbol-function 'harness-cache-around-p) (lambda (&rest _) nil)))
      (let ((sid (harness-cache-compact-test-session)))
        (harness-cache-compact-test--event sid)
        (harness-cache-compact-test--wait)
        (should-not (harness-cache-compact-test--compactions sid))
        (should-not (harness-cache-compact-test--notes sid))
        (should-not harness-cache-compact-test--compacted)
        (should (plist-get (harness-call 'session/get sid) :cache))
        (should (cl-some (lambda (h) (string-match-p "Compaction failed" h))
                         (harness-cache-compact-test--hints sid)))))))

(ert-deftest harness-cache-compact-forgets-a-session-that-is-deleted ()
  "What is kept of a session that is gone goes with it."
  (harness-cache-compact-test-with
    (let ((sid (harness-cache-compact-test-session)))
      (puthash sid (harness-make-promise) harness-cache-compact--running)
      (harness-call 'session/delete sid)
      (should-not (gethash sid harness-cache-compact--running)))))

;;;; With keeping the cache warm

(ert-deftest harness-cache-compact-waits-for-the-user-to-be-gone-from-a-cache-kept-warm ()
  "Together: while the user is around the cache is read again and the
conversation left alone; once they are gone, at the next lapse, it is
compacted -- cheaper from a cache that is hot than from one that lapsed."
  (harness-cache-compact-test-with
    (harness-test-load-module 'cache-warm)
    (let ((harness-cache-warm t)
          (requests nil))
      (harness-define-provider 'api
        :label "API"
        :models (lambda () (harness-resolved (list (list :name "m" :label "API M" :context-window 200000))))
        :complete (lambda (req)
                    (push req requests)
                    (let ((on-event (plist-get req :on-event)))
                      (run-at-time 0.01 nil
                                   (lambda ()
                                     (funcall on-event '(:type usage :input 12 :output 2 :cache-read 3000
                                                               :cache-write 0 :cost 0.001))
                                     (funcall on-event '(:type done :stop-reason end-turn)))))
                    (list :cancel #'ignore)))
      (unwind-protect
          (let ((sid (harness-cache-compact-test-session :model "api:m")))
            ;; Around: read again, not compacted.
            (harness-call 'cache/active sid)
            (harness-cache-compact-test--event sid)
            (harness-test-wait (lambda () (and requests (zerop (hash-table-count harness-cache-warm--refreshing)))) 5
                               "the refresh")
            (should (= 1 (length requests)))
            (should-not (harness-cache-compact-test--compactions sid))
            (should-not (harness-cache-compact-test--notes sid))
            ;; Gone: compacted.
            (harness-call 'cache/active sid 0)
            (cl-letf (((symbol-function 'harness-cache-around-p) (lambda (&rest _) nil)))
              (harness-cache-compact-test--event sid))
            (harness-cache-compact-test--wait)
            (should (= 1 (length requests)))
            (should (= 1 (length (harness-cache-compact-test--compactions sid)))))
        (remhash 'api harness-providers)
        (harness-provider--forget 'api)))))

(provide 'harness-cache-compact-test)
;;; harness-cache-compact-test.el ends here
