;;; harness-tools-compact-test.el --- Tests for the compact tool  -*- lexical-binding: t; -*-

;;; Commentary:

;; The `compact' tool (harness-tools-compact.el): what it offers the
;; model, that it goes through `compaction/compact', that an idle
;; session is compacted at once, that a running turn is queued for its
;; next boundary by default or cancelled by `:mode "interrupt"', and
;; that a refused call compacts nothing.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-compaction--running)
(defvar harness-compaction--pending)
(defvar harness-compaction--context-reserve)
(declare-function harness-compaction-busy-p "harness-compaction")
(declare-function harness-agent-running-p "harness-agent")

(defmacro harness-tools-compact-test-with (&rest body)
  "Load the state layer with the demo provider, compaction and the tool, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent compaction tools-compact))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-compaction--running)
     (clrhash harness-compaction--pending)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override nil)
           (harness-compaction--context-reserve 1000)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defconst harness-tools-compact-test-script
  '((:type text :delta "BRIEF SUMMARY") (:type done :stop-reason end-turn))
  "The summary the demo provider writes for the tool's request.")

(defun harness-tools-compact-test-session ()
  "Create a demo session (window 8000) with one answered exchange; return its id."
  (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                     :model "demo:scripted" :context-window 8000)
                       :id)))
    (harness-call 'session/append id '(:kind user :content "please refactor the parser"))
    (harness-call 'session/append id '(:kind assistant :content "Done: parser.el rewritten"))
    id))

(defun harness-tools-compact-test-call (sid input)
  "Call the compact tool for SID with INPUT; return a promise of the result."
  (harness-call 'tools/execute sid (list :id (harness-short-id 6) :name "compact" :input input)))

(defun harness-tools-compact-test-compactions (id)
  "Return the compaction nodes of ID, oldest first."
  (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'compaction))
                    (harness-call 'session/nodes id)))

(defun harness-tools-compact-test-running (id &optional handle)
  "Put a fake running turn in the agent's table for ID, and return it."
  (let ((turn (make-harness-agent-turn :session-id id :handle handle)))
    (puthash id turn harness-agent--turns)
    turn))

(ert-deftest harness-tools-compact-is-offered-to-every-session ()
  "The compact tool is in a session's tools, with its label, kind and kinds."
  (harness-tools-compact-test-with
    (let* ((id (harness-tools-compact-test-session))
           (spec (cl-find-if (lambda (s) (equal "compact" (plist-get s :name)))
                             (harness-call 'tools/list id))))
      (should spec)
      (should (equal "Compact the conversation" (plist-get spec :label)))
      (should (eq 'meta (plist-get spec :kind)))
      (let* ((properties (plist-get (plist-get spec :schema) :properties)))
        (should (equal '("summary" "brief" "transcript" "fresh" "truncate")
                       (plist-get (plist-get properties :kind) :enum)))
        (should (equal '("queue" "interrupt") (plist-get (plist-get properties :mode) :enum))))
      ;; The catalogue, offered to no model, holds it too.
      (should (cl-find-if (lambda (s) (equal "compact" (plist-get s :name)))
                          (harness-call 'tools/list))))))

(ert-deftest harness-tools-compact-compacts-an-idle-session ()
  "A call on a session with no turn running compacts at once, through
`compaction/compact', and says what it became.  `:reason' is kept with
the compaction."
  (harness-tools-compact-test-with
    (let* ((id (harness-tools-compact-test-session))
           (result (harness-await (harness-tools-compact-test-call id '(:kind "transcript")))))
      (should-not (plist-get result :is-error))
      (should (string-match-p "compacted" (plist-get result :content)))
      (let ((nodes (harness-tools-compact-test-compactions id)))
        (should (= 1 (length nodes)))
        (should (equal "transcript" (harness-node-compaction-kind (car nodes)))))
      (should-not (gethash id harness-compaction--pending)))
    ;; A model-written kind: the request is made, the reason is on the node.
    (let* ((id (harness-tools-compact-test-session))
           (harness-provider-demo-script-override harness-tools-compact-test-script)
           (result (harness-await (harness-tools-compact-test-call
                                   id '(:kind "brief" :reason "the context is filling")))))
      (should-not (plist-get result :is-error))
      (should (string-match-p "brief summary" (plist-get result :content)))
      (let ((node (car (harness-tools-compact-test-compactions id))))
        (should (equal "brief" (harness-node-compaction-kind node)))
        (should (string-prefix-p "BRIEF SUMMARY" (plist-get node :content)))
        (should (equal "the context is filling" (plist-get (plist-get node :meta) :reason)))))))

(ert-deftest harness-tools-compact-queues-for-a-running-turn ()
  "The default mode queues the compaction for the running turn's next
boundary: the call answers at once, nothing is compacted yet, and the
turn goes on, not cancelled."
  (harness-tools-compact-test-with
    (let* ((id (harness-tools-compact-test-session))
           (turn (harness-tools-compact-test-running id))
           (result (harness-await (harness-tools-compact-test-call id '(:kind "brief")))))
      (should-not (plist-get result :is-error))
      (should (string-match-p "queued" (plist-get result :content)))
      (should (string-match-p "next boundary" (plist-get result :content)))
      (should (gethash id harness-compaction--pending))
      (should-not (harness-tools-compact-test-compactions id))
      (should-not (harness-agent-turn-cancelled turn))
      (should (harness-agent-running-p id)))))

(ert-deftest harness-tools-compact-interrupt-cancels-the-turn ()
  "An `:mode \"interrupt\"' call cancels the running turn at once and
compacts once it is over; nothing is compacted before that."
  (harness-tools-compact-test-with
    (let* ((id (harness-tools-compact-test-session))
           (cancelled nil)
           (turn (harness-tools-compact-test-running
                  id (list :cancel (lambda () (setq cancelled t)))))
           (result (harness-await (harness-tools-compact-test-call
                                   id '(:kind "transcript" :mode "interrupt")))))
      (should-not (plist-get result :is-error))
      (should (string-match-p "cancelled" (plist-get result :content)))
      (should cancelled)
      (should (harness-agent-turn-cancelled turn))
      (should-not (harness-tools-compact-test-compactions id))
      ;; The turn ends: the queued compaction runs.
      (remhash id harness-agent--turns)
      (harness-emit 'agent/turn-ended id 'cancelled)
      (harness-test-wait (lambda () (harness-tools-compact-test-compactions id)) 5
                         "the interrupted compaction")
      (should (equal "transcript"
                     (harness-node-compaction-kind
                      (car (harness-tools-compact-test-compactions id)))))
      (should-not (gethash id harness-compaction--pending)))))

(ert-deftest harness-tools-compact-refuses-what-it-cannot-do ()
  "An unknown kind or mode is a refused call that compacts nothing."
  (harness-tools-compact-test-with
    (let* ((id (harness-tools-compact-test-session))
           (kind (harness-await (harness-tools-compact-test-call id '(:kind "sideways"))))
           (mode (harness-await (harness-tools-compact-test-call
                                 id '(:kind "summary" :mode "later")))))
      (should (plist-get kind :is-error))
      (should (string-match-p "Unknown kind sideways" (plist-get kind :content)))
      (should (plist-get mode :is-error))
      (should (string-match-p "Unknown mode later" (plist-get mode :content)))
      (should-not (harness-tools-compact-test-compactions id))
      (should-not (gethash id harness-compaction--pending)))))

(ert-deftest harness-tools-compact-busy-compaction-is-a-no-op ()
  "While a compaction runs, the tool says so rather than starting a second."
  (harness-tools-compact-test-with
    (let* ((id (harness-tools-compact-test-session))
           (result nil))
      (puthash id (harness-resolved '(:kind compaction :content "x")) harness-compaction--running)
      (setq result (harness-await (harness-tools-compact-test-call id '(:kind "summary"))))
      (should-not (plist-get result :is-error))
      (should (string-match-p "already under way" (plist-get result :content)))
      (should-not (harness-tools-compact-test-compactions id))
      (remhash id harness-compaction--running))))

(provide 'harness-tools-compact-test)
;;; harness-tools-compact-test.el ends here
