;;; harness-workspace-speech-test.el --- Tests for the workspace speech floor  -*- lexical-binding: t; -*-

;;; Commentary:

;; The floor's rules, one at a time: one speaker, FIFO, idempotent by
;; node, solo that holds the others instead of stopping them, the
;; interrupted utterance yielding, unsolo that releases one entry, the
;; bounded queue, a removed thread, a lost speaker, a stale report, and a
;; restart that reads the same floor back.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)

(defvar harness-acp--server-enabled)
(defvar harness-naming-auto)
(defvar harness-workspace-speech--table)
(defvar harness-workspace-speech--subscribed)
(defvar harness-workspace--table)
(defvar harness-workspace--loaded)

(defmacro harness-workspace-speech-test-with (&rest body)
  "Load the workspace and its speech floor, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil)
           (harness-naming-auto nil)
           (default-directory (expand-file-name "lisp/" harness-state-directory)))
       (dolist (module '(store project config provider provider-demo tools session agent
                               acp logseq memory workspace-knowledge workspace-box workspace
                               workspace-speech))
         (harness-test-load-module module))
       (setq harness-workspace--subscribed nil
             harness-workspace-speech--subscribed nil
             harness-workspace--loaded nil)
       (clrhash harness-workspace--table)
       (clrhash harness-workspace-speech--table)
       (unwind-protect (progn ,@body)
         (harness-workspace-speech--shutdown)))))

(defun harness-workspace-speech-test-workspace ()
  "Create a workspace with two threads for a test.
Return (WORKSPACE-ID THREAD-1 THREAD-2)."
  (let* ((workspace (harness-call 'workspace/create
                                  :name "Home"
                                  :root (expand-file-name "workspace/" harness-state-directory)))
         (id (plist-get workspace :id))
         (one (harness-call 'workspace/thread/create id "Kitchen"))
         (two (harness-call 'workspace/thread/create id "Garden")))
    (list id (plist-get one :id) (plist-get two :id))))

(defun harness-workspace-speech-test-texts (entries)
  "Return the texts of ENTRIES."
  (mapcar (lambda (entry) (plist-get entry :text)) entries))

(ert-deftest harness-workspace-speech-one-speaker-and-a-stable-order ()
  "Two offers never speak together, and the queue keeps arrival order."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (harness-call 'workspace/speech/enqueue id one "First." (list :node "n1"))
      (harness-call 'workspace/speech/enqueue id two "Second." (list :node "n2"))
      (harness-call 'workspace/speech/enqueue id one "Third." (list :node "n3"))
      (let ((floor (harness-call 'workspace/speech id)))
        (should (equal "First." (plist-get (plist-get floor :speaking) :text)))
        (should (equal '("Second." "Third.")
                       (harness-workspace-speech-test-texts (plist-get floor :waiting))))
        (should (equal one (plist-get floor :active)))
        (should (= 2 (plist-get floor :count))))
      ;; The first finishes; the next speaks; the third still waits.
      (let* ((floor (harness-call 'workspace/speech id))
             (first (plist-get (plist-get floor :speaking) :id)))
        (harness-call 'workspace/speech/advance id first "finished")
        (setq floor (harness-call 'workspace/speech id))
        (should (equal "Second." (plist-get (plist-get floor :speaking) :text)))
        (should (equal '("Third.")
                       (harness-workspace-speech-test-texts (plist-get floor :waiting))))
        ;; The finished one is history, never spoken again.
        (should (equal '("First.")
                       (harness-workspace-speech-test-texts (plist-get floor :recent))))
        (should (equal "finished" (plist-get (car (plist-get floor :recent)) :outcome))))
      ;; Nothing replays on a second read.
      (let ((floor (harness-call 'workspace/speech id)))
        (should (equal "Second." (plist-get (plist-get floor :speaking) :text)))
        (should (equal '("Third.")
                       (harness-workspace-speech-test-texts (plist-get floor :waiting))))))))

(ert-deftest harness-workspace-speech-enqueue-is-idempotent-by-node ()
  "The same assistant node offered twice is one entry, in one place."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (let* ((first (harness-call 'workspace/speech/enqueue id one "Said once." (list :node "n1")))
             (entry (plist-get first :entry)))
        (harness-call 'workspace/speech/enqueue id two "Someone else." (list :node "n2"))
        (let* ((again (harness-call 'workspace/speech/enqueue id one "Said once." (list :node "n1")))
               (floor (plist-get again :floor)))
          (should (equal (plist-get entry :id) (plist-get (plist-get again :entry) :id)))
          ;; One speaking, one waiting: the repeat made no third entry.
          (should (equal '("Someone else.")
                         (harness-workspace-speech-test-texts (plist-get floor :waiting))))
          (should (equal "speaking" (plist-get (plist-get again :entry) :state))))))))

(ert-deftest harness-workspace-speech-revision-only-grows ()
  "Every change is a new, larger revision, implicit ones included."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace))
                 (revisions nil))
      (push (plist-get (harness-call 'workspace/speech id) :revision) revisions)
      (push (plist-get (harness-call 'workspace/speech/enqueue id one "One." (list :node "n1"))
                       :revision)
            revisions)
      (push (plist-get (harness-call 'workspace/speech/solo id one) :revision) revisions)
      (push (plist-get (harness-call 'workspace/speech/unsolo id) :revision) revisions)
      (push (plist-get (harness-call 'workspace/speech/enqueue id two "Two." (list :node "n2"))
                       :revision)
            revisions)
      (push (plist-get (harness-call 'workspace/speech/cancel id) :revision) revisions)
      (setq revisions (nreverse revisions))
      (should (= (length revisions) (length (delete-dups (copy-sequence revisions)))))
      (should (cl-every (lambda (pair) (< (car pair) (cadr pair)))
                        (cl-mapcar #'list revisions (cdr revisions)))))))

(ert-deftest harness-workspace-speech-solo-holds-the-others-and-interrupts ()
  "Solo silences another thread's utterance, keeps its words, and starts none."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (harness-call 'workspace/speech/enqueue id two "Garden speaks." (list :node "n1"))
      (harness-call 'workspace/speech/enqueue id one "Kitchen waits." (list :node "n2"))
      (let* ((floor (harness-call 'workspace/speech/solo id one))
             (recent (car (plist-get floor :recent))))
        (should (equal one (plist-get floor :solo)))
        (should (equal "Kitchen" (plist-get floor :solo-title)))
        ;; The other thread's utterance yielded at once, and says why.
        (should (equal "Garden speaks." (plist-get recent :text)))
        (should (equal "cancelled" (plist-get recent :state)))
        (should (equal "interrupted" (plist-get recent :outcome)))
        (should (equal "Solo" (plist-get recent :why)))
        ;; The soloed thread's own entry speaks, alone.
        (should (equal "Kitchen waits." (plist-get (plist-get floor :speaking) :text)))
        (should (null (plist-get floor :waiting))))
      ;; A new arrival from another thread waits, held, and never speaks.
      (harness-call 'workspace/speech/enqueue id two "Garden again." (list :node "n3"))
      (let* ((floor (harness-call 'workspace/speech id))
             (waiting (car (plist-get floor :waiting))))
        (should (equal "Garden again." (plist-get waiting :text)))
        (should (equal "queued" (plist-get waiting :state)))
        (should (equal "Solo" (plist-get waiting :held)))
        (should (equal "Kitchen waits." (plist-get (plist-get floor :speaking) :text))))
      ;; Finishing the soloed thread's words still leaves the held one held.
      (let* ((floor (harness-call 'workspace/speech id))
             (entry (plist-get (plist-get floor :speaking) :id)))
        (harness-call 'workspace/speech/advance id entry "finished")
        (setq floor (harness-call 'workspace/speech id))
        (should (null (plist-get floor :speaking)))
        (should (equal '("Garden again.")
                       (harness-workspace-speech-test-texts (plist-get floor :waiting))))
        (should (equal one (plist-get floor :active)))
        ;; Clearing solo releases one entry, not a burst.
        (setq floor (harness-call 'workspace/speech/unsolo id))
        (should (null (plist-get floor :solo)))
        (should (equal "Garden again." (plist-get (plist-get floor :speaking) :text)))
        (should (null (plist-get floor :waiting)))))))

(ert-deftest harness-workspace-speech-solo-does-not-interrupt-the-soloed-thread ()
  "Soloing the thread that is speaking lets its words finish."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (harness-call 'workspace/speech/enqueue id one "Kitchen speaks." (list :node "n1"))
      (harness-call 'workspace/speech/enqueue id two "Garden waits." (list :node "n2"))
      (let ((floor (harness-call 'workspace/speech/solo id one)))
        (should (equal "Kitchen speaks." (plist-get (plist-get floor :speaking) :text)))
        (should (null (plist-get floor :recent)))))))

(ert-deftest harness-workspace-speech-changing-the-solo-target ()
  "Soloing another thread twice in a row keeps exactly one solo."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (harness-call 'workspace/speech/enqueue id one "One." (list :node "n1"))
      (harness-call 'workspace/speech/enqueue id two "Two." (list :node "n2"))
      (harness-call 'workspace/speech/solo id one)
      (let ((floor (harness-call 'workspace/speech/solo id two)))
        (should (equal two (plist-get floor :solo)))
        ;; Solo is one thread, not a set: the first solo is gone.
        (should (equal "Garden" (plist-get floor :solo-title)))
        ;; The one thread's utterance yielded with the change of target.
        (should (equal "Solo" (plist-get (car (plist-get floor :recent)) :why)))
        (should (equal "Two." (plist-get (plist-get floor :speaking) :text))))
      (let ((floor (harness-call 'workspace/speech/unsolo id)))
        (should (null (plist-get floor :solo)))
        ;; Clearing solo is not a burst: the utterance that was playing
        ;; goes on, nothing else starts beside it, and the words solo
        ;; interrupted are history, never replayed.
        (should (equal "Two." (plist-get (plist-get floor :speaking) :text)))
        (should (null (plist-get floor :waiting)))
        (let ((interrupted (cl-find "One." (plist-get floor :recent)
                                    :key (lambda (entry) (plist-get entry :text))
                                    :test #'equal)))
          (should interrupted)
          (should (equal "interrupted" (plist-get interrupted :outcome))))))))

(ert-deftest harness-workspace-speech-advance-reports-and-stale-reports ()
  "A failure says why; a report about an entry that yielded moves nothing."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (harness-call 'workspace/speech/enqueue id one "One." (list :node "n1"))
      (harness-call 'workspace/speech/enqueue id two "Two." (list :node "n2"))
      (let* ((floor (harness-call 'workspace/speech id))
             (first (plist-get (plist-get floor :speaking) :id)))
        (harness-call 'workspace/speech/advance id first "failed" "No audio")
        (setq floor (harness-call 'workspace/speech id))
        (should (equal "Two." (plist-get (plist-get floor :speaking) :text)))
        (should (equal "failed" (plist-get (car (plist-get floor :recent)) :outcome)))
        (should (equal "No audio" (plist-get (car (plist-get floor :recent)) :why)))
        ;; The same report again, and a report about a stranger, apply to
        ;; nothing: the queue does not move twice for one utterance.
        (let ((again (harness-call 'workspace/speech/advance id first "finished")))
          (should (null (plist-get again :applied)))
          (should (equal "Two." (plist-get (plist-get (plist-get again :floor) :speaking) :text))))
        (let ((stale (harness-call 'workspace/speech/advance id "sp-nope" "finished")))
          (should (null (plist-get stale :applied)))
          (should (equal "Two." (plist-get (plist-get (plist-get stale :floor) :speaking) :text))))))))

(ert-deftest harness-workspace-speech-cancel-is-visible-and-final ()
  "A cancelled entry leaves the queue with a reason and is never spoken."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (harness-call 'workspace/speech/enqueue id one "One." (list :node "n1"))
      (harness-call 'workspace/speech/enqueue id two "Two." (list :node "n2"))
      (harness-call 'workspace/speech/cancel id two)
      (let ((floor (harness-call 'workspace/speech id)))
        (should (equal '("Two.")
                       (harness-workspace-speech-test-texts (plist-get floor :recent))))
        (should (equal "cancelled" (plist-get (car (plist-get floor :recent)) :outcome)))
        (should (null (plist-get floor :waiting)))
        (should (equal "One." (plist-get (plist-get floor :speaking) :text))))
      ;; Cancelling everything is honest about what it took.
      (let ((floor (harness-call 'workspace/speech/cancel id)))
        (should (null (plist-get floor :speaking)))
        (should (null (plist-get floor :waiting)))
        (should (= 2 (length (plist-get floor :recent))))))))

(ert-deftest harness-workspace-speech-a-removed-thread-is-skipped ()
  "A deleted thread's entries are cancelled with a reason, and the floor answers."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (harness-call 'workspace/speech/enqueue id one "One." (list :node "n1"))
      (harness-call 'workspace/speech/enqueue id two "Two." (list :node "n2"))
      (harness-call 'workspace/thread/delete id one)
      (let ((floor (harness-call 'workspace/speech id)))
        (should (equal "Two." (plist-get (plist-get floor :speaking) :text)))
        (let ((entry (cl-find "One." (plist-get floor :recent)
                              :key (lambda (item) (plist-get item :text)) :test #'equal)))
          (should entry)
          (should (equal "Thread removed" (plist-get entry :why)))
          (should (equal "cancelled" (plist-get entry :outcome))))
        ;; The floor names a thread that no longer exists without failing.
        (should (equal two (plist-get floor :active))))
      ;; Solo on a removed thread is not accepted, and says so.
      (should-error (harness-call 'workspace/speech/solo id one))
      (let ((floor (harness-call 'workspace/speech id)))
        (should (null (plist-get floor :solo)))))))

(ert-deftest harness-workspace-speech-a-removed-thread-holds-no-solo ()
  "Deleting the soloed thread leaves the others free, still held in order."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (harness-call 'workspace/speech/enqueue id one "One." (list :node "n1"))
      (harness-call 'workspace/speech/solo id one)
      (harness-call 'workspace/speech/enqueue id two "Two." (list :node "n2"))
      (should (equal "Solo" (plist-get (car (plist-get (harness-call 'workspace/speech id) :waiting))
                                       :held)))
      (harness-call 'workspace/thread/delete id one)
      (let ((floor (harness-call 'workspace/speech id)))
        (should (null (plist-get floor :solo)))
        (should (equal "Two." (plist-get (plist-get floor :speaking) :text)))))))

(ert-deftest harness-workspace-speech-the-queue-is-bounded-visibly ()
  "Beyond the limit the oldest waiting entry is cancelled with a reason."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace))
                 (harness-workspace-speech-queue-limit 3))
      (dotimes (n 5)
        (harness-call 'workspace/speech/enqueue id (if (cl-evenp n) one two)
                      (format "Say %d." n) (list :node (format "n%d" n))))
      (let ((floor (harness-call 'workspace/speech id)))
        (should (equal "Say 0." (plist-get (plist-get floor :speaking) :text)))
        (should (= 3 (length (plist-get floor :waiting))))
        (should (cl-some (lambda (entry)
                           (and (equal "Queue full" (plist-get entry :why))
                                (equal "Say 1." (plist-get entry :text))))
                         (plist-get floor :recent)))))))

(ert-deftest harness-workspace-speech-a-lost-speaker-is-recovered ()
  "A claim that expired is cancelled and the next entry released."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace))
                 (harness-workspace-speech-claim-seconds 30))
      (harness-call 'workspace/speech/enqueue id one "One." (list :node "n1"))
      (harness-call 'workspace/speech/enqueue id two "Two." (list :node "n2"))
      (let* ((floor (harness-call 'workspace/speech id))
             (entry (plist-get (plist-get floor :speaking) :id)))
        (harness-call 'workspace/speech/claim id entry "desk")
        ;; The client is gone: its claim ages out.
        (let ((state (harness-workspace-speech--load id)))
          (setf (plist-get (cl-find entry (plist-get state :entries)
                                    :key (lambda (item) (plist-get item :id)) :test #'equal)
                           :claimed-at)
                (- (float-time) 120))
          (puthash id state harness-workspace-speech--table))
        (setq floor (harness-call 'workspace/speech id))
        (should (equal "Two." (plist-get (plist-get floor :speaking) :text)))
        (should (equal "Speaker lost" (plist-get (car (plist-get floor :recent)) :why)))
        (should (equal "failed" (plist-get (car (plist-get floor :recent)) :outcome)))))))

(ert-deftest harness-workspace-speech-one-client-claims ()
  "The first claimant speaks and a second client is told to stay silent."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (harness-call 'workspace/speech/enqueue id one "One." (list :node "n1"))
      (let* ((entry (plist-get (plist-get (harness-call 'workspace/speech id) :speaking) :id))
             (desk (harness-call 'workspace/speech/claim id entry "desk"))
             (phone (harness-call 'workspace/speech/claim id entry "phone")))
        (should (plist-get desk :claimed))
        (should (null (plist-get phone :claimed)))
        (should (equal "desk" (plist-get phone :holder)))
        ;; The holder asking again keeps its claim and stays silent.
        (should (plist-get (harness-call 'workspace/speech/claim id entry "desk") :claimed))
        ;; A claim on an entry that already yielded claims nothing.
        (harness-call 'workspace/speech/advance id entry "finished")
        (should (null (plist-get (harness-call 'workspace/speech/claim id entry "desk") :claimed)))))))

(ert-deftest harness-workspace-speech-clear-keeps-the-queue ()
  "Clearing the history of the floor leaves what waits and what speaks."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (harness-call 'workspace/speech/enqueue id one "One." (list :node "n1"))
      (harness-call 'workspace/speech/enqueue id two "Two." (list :node "n2"))
      (harness-call 'workspace/speech/advance id
                    (plist-get (plist-get (harness-call 'workspace/speech id) :speaking) :id)
                    "finished")
      (let ((floor (harness-call 'workspace/speech/clear id)))
        (should (null (plist-get floor :recent)))
        (should (equal "Two." (plist-get (plist-get floor :speaking) :text)))))))

(ert-deftest harness-workspace-speech-a-restart-reads-the-same-floor ()
  "The floor is the workspace's record: a fresh read finds it unchanged."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (harness-call 'workspace/speech/enqueue id one "One." (list :node "n1"))
      (harness-call 'workspace/speech/enqueue id two "Two." (list :node "n2"))
      (harness-call 'workspace/speech/solo id one)
      (let ((before (harness-call 'workspace/speech id)))
        ;; A client that connected afterwards reads it from the store.
        (clrhash harness-workspace-speech--table)
        (let ((after (harness-call 'workspace/speech id)))
          (should (equal (plist-get before :revision) (plist-get after :revision)))
          (should (equal (plist-get before :solo) (plist-get after :solo)))
          (should (equal (plist-get before :speaking) (plist-get after :speaking)))
          (should (equal (harness-workspace-speech-test-texts (plist-get before :waiting))
                         (harness-workspace-speech-test-texts (plist-get after :waiting)))))))))

(ert-deftest harness-workspace-speech-a-reply-is-offered-once ()
  "A workspace episode's final assistant node reaches the floor, once.
Streaming is not offered, so one answer is one entry."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace))
                 (session (plist-get (harness-call 'session/create
                                                   :cwd (expand-file-name "workspace/" harness-state-directory)
                                                   :kind 'workspace
                                                   :ext (list :workspace id :thread one :episode 1))
                                      :id)))
      (harness-call 'session/append session (list :kind 'assistant :content "Half an answer"))
      (let ((node (car (harness-call 'session/nodes session))))
        ;; A streaming delta is not speech yet.
        (harness-call 'session/update-node session (plist-get node :id)
                      :content "Half an answer, then the rest." :transient t)
        (should (null (plist-get (harness-call 'workspace/speech id) :speaking)))
        ;; The final write is.
        (harness-call 'session/update-node session (plist-get node :id)
                      :content "Half an answer, then the rest.")
        (let ((floor (harness-call 'workspace/speech id)))
          (should (equal "Half an answer, then the rest."
                         (plist-get (plist-get floor :speaking) :text)))
          (should (equal session (plist-get (plist-get floor :speaking) :session)))
          (should (equal "reply" (plist-get (plist-get floor :speaking) :source))))
        ;; The same node announced again is the same entry: still one
        ;; speaking, still nothing waiting, and no second copy anywhere.
        (harness-call 'session/update-node session (plist-get node :id)
                      :content "Half an answer, then the rest.")
        (let ((floor (harness-call 'workspace/speech id)))
          (should (equal "Half an answer, then the rest."
                         (plist-get (plist-get floor :speaking) :text)))
          (should (null (plist-get floor :waiting)))
          (should (null (plist-get floor :recent)))
          (should (= 0 (plist-get floor :count))))))))

(ert-deftest harness-workspace-speech-disabled-floor-takes-nothing ()
  "A disabled floor is not filled by replies, and keeps what it had."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace))
                 (session (plist-get (harness-call 'session/create
                                                   :cwd (expand-file-name "workspace/" harness-state-directory)
                                                   :kind 'workspace
                                                   :ext (list :workspace id :thread one :episode 1))
                                      :id)))
      (harness-call 'workspace/speech/enqueue id one "Kept." (list :node "n1"))
      (harness-call 'workspace/speech/update id :enabled nil)
      (harness-call 'session/append session (list :kind 'assistant :content "Not offered."))
      (let ((node (car (harness-call 'session/nodes session))))
        (harness-call 'session/update-node session (plist-get node :id) :content "Not offered."))
      (let ((floor (harness-call 'workspace/speech id)))
        (should (null (plist-get floor :enabled)))
        (should (equal "Kept." (plist-get (plist-get floor :speaking) :text)))
        (should (null (plist-get floor :waiting)))))))

(ert-deftest harness-workspace-speech-empty-text-is-no-entry ()
  "Blank words make no entry and change no revision."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (let* ((before (harness-call 'workspace/speech id))
             (answer (harness-call 'workspace/speech/enqueue id one "   " (list :node "n1"))))
        (should (null (plist-get answer :entry)))
        (should (= (plist-get before :revision) (plist-get answer :revision)))
        (should (null (plist-get (plist-get answer :floor) :speaking)))))))


;;;; The global hold

(ert-deftest harness-workspace-speech-hold-keeps-the-playing-words ()
  "A hold keeps the utterance where it is instead of yielding it."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (harness-call 'workspace/speech/enqueue id one "A long answer." (list :node "n1"))
      (harness-call 'workspace/speech/enqueue id two "Another answer." (list :node "n2"))
      (let* ((floor (harness-call 'workspace/speech/hold id (list :played 4.5)))
             (current (plist-get floor :speaking)))
        (should (plist-get floor :hold))
        (should (plist-get floor :held))
        ;; Kept, not yielded: still the same entry, with its position.
        (should (equal "A long answer." (plist-get current :text)))
        (should (equal "held" (plist-get current :state)))
        (should (= 4.5 (plist-get current :played)))
        (should (null (plist-get floor :recent)))
        ;; The other thread waits, visible, and says why it is not playing.
        (should (equal "Another answer."
                       (plist-get (car (plist-get floor :waiting)) :text)))
        (should (equal "Hold" (plist-get (car (plist-get floor :waiting)) :why)))
        (should (equal one (plist-get floor :active))))
      ;; Holding again is one hold, and does not move the position.
      (let ((floor (harness-call 'workspace/speech/hold id (list :played 9.0))))
        (should (= 4.5 (plist-get (plist-get floor :speaking) :played)))
        (should (= 1 (length (plist-get floor :waiting))))))))

(ert-deftest harness-workspace-speech-hold-does-not-start-anything ()
  "While held, a new arrival waits and nothing speaks beside it."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (harness-call 'workspace/speech/hold id)
      (harness-call 'workspace/speech/enqueue id one "First." (list :node "n1"))
      (harness-call 'workspace/speech/enqueue id two "Second." (list :node "n2"))
      (let ((floor (harness-call 'workspace/speech id)))
        (should (plist-get floor :hold))
        (should (null (plist-get floor :speaking)))
        (should (equal '("First." "Second.")
                       (harness-workspace-speech-test-texts (plist-get floor :waiting)))))
      ;; A client is told to stay silent rather than speaking over the hold.
      (let* ((floor (harness-call 'workspace/speech id))
             (entry (plist-get (car (plist-get floor :waiting)) :id))
             (claim (harness-call 'workspace/speech/claim id entry "desk")))
        (should (null (plist-get claim :claimed)))
        (should (plist-get claim :held))))))

(ert-deftest harness-workspace-speech-resume-releases-one-and-keeps-order ()
  "Resume starts the held words again, then one waiting entry at a time."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (harness-call 'workspace/speech/enqueue id one "Held answer." (list :node "n1"))
      (harness-call 'workspace/speech/enqueue id two "Second answer." (list :node "n2"))
      (harness-call 'workspace/speech/enqueue id one "Third answer." (list :node "n3"))
      (harness-call 'workspace/speech/hold id (list :played 2.0))
      (let ((floor (harness-call 'workspace/speech/resume id)))
        (should (null (plist-get floor :hold)))
        ;; The same words go on from where they stopped...
        (should (equal "Held answer." (plist-get (plist-get floor :speaking) :text)))
        (should (equal "speaking" (plist-get (plist-get floor :speaking) :state)))
        (should (= 2.0 (plist-get (plist-get floor :speaking) :played)))
        ;; ...and nothing else starts beside them.
        (should (equal '("Second answer." "Third answer.")
                       (harness-workspace-speech-test-texts (plist-get floor :waiting))))
        (should (null (plist-get floor :recent))))
      ;; Finishing it releases exactly the next one.
      (harness-call 'workspace/speech/advance id
                    (plist-get (plist-get (harness-call 'workspace/speech id) :speaking) :id)
                    "finished")
      (let ((floor (harness-call 'workspace/speech id)))
        (should (equal "Second answer." (plist-get (plist-get floor :speaking) :text)))
        (should (equal '("Third answer.")
                       (harness-workspace-speech-test-texts (plist-get floor :waiting))))))))

(ert-deftest harness-workspace-speech-resume-restarts-when-asked ()
  "A client that cannot seek asks for the held words from the start."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (harness-call 'workspace/speech/enqueue id one "Held answer." (list :node "n1"))
      (harness-call 'workspace/speech/enqueue id two "Second answer." (list :node "n2"))
      (harness-call 'workspace/speech/hold id (list :played 3.0))
      (let ((floor (harness-call 'workspace/speech/resume id (list :restart t))))
        (should (equal "Held answer." (plist-get (plist-get floor :speaking) :text)))
        ;; Started over, at the head: the second still waits.
        (should (null (plist-get (plist-get floor :speaking) :played)))
        (should (equal '("Second answer.")
                       (harness-workspace-speech-test-texts (plist-get floor :waiting))))))))

(ert-deftest harness-workspace-speech-hold-and-solo-are-separate ()
  "A hold and a solo are two facts; neither clears the other."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (harness-call 'workspace/speech/enqueue id one "One." (list :node "n1"))
      (harness-call 'workspace/speech/enqueue id two "Two." (list :node "n2"))
      (harness-call 'workspace/speech/hold id)
      (let ((floor (harness-call 'workspace/speech/solo id one)))
        ;; Soloing while held keeps the hold and the frozen words.
        (should (equal one (plist-get floor :solo)))
        (should (plist-get floor :hold))
        (should (equal "One." (plist-get (plist-get floor :speaking) :text)))
        (should (equal "held" (plist-get (plist-get floor :speaking) :state))))
      ;; Resuming keeps the solo, and the other thread is still held by it.
      (let ((floor (harness-call 'workspace/speech/resume id)))
        (should (equal one (plist-get floor :solo)))
        (should (null (plist-get floor :hold)))
        (should (equal "One." (plist-get (plist-get floor :speaking) :text)))
        (should (equal "Solo"
                       (plist-get (car (plist-get floor :waiting)) :held))))
      ;; Clearing the solo keeps nothing else: the hold is already gone.
      (let ((floor (harness-call 'workspace/speech/unsolo id)))
        (should (null (plist-get floor :solo)))
        (should (equal '("Two.")
                       (harness-workspace-speech-test-texts (plist-get floor :waiting))))
        (should (equal "One." (plist-get (plist-get floor :speaking) :text)))))))

(ert-deftest harness-workspace-speech-hold-survives-a-cancel ()
  "Cancelling what waits does not lift the user's hold."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (harness-call 'workspace/speech/hold id)
      (harness-call 'workspace/speech/enqueue id one "One." (list :node "n1"))
      (harness-call 'workspace/speech/cancel id)
      (harness-call 'workspace/speech/enqueue id two "Two." (list :node "n2"))
      (let ((floor (harness-call 'workspace/speech id)))
        (should (plist-get floor :hold))
        (should (null (plist-get floor :speaking)))))))

(ert-deftest harness-workspace-speech-a-held-utterance-does-not-age-out ()
  "A pause is not a lost speaker: the claim is kept while held."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace))
                 (harness-workspace-speech-claim-seconds 30))
      (harness-call 'workspace/speech/enqueue id one "One." (list :node "n1"))
      (let* ((floor (harness-call 'workspace/speech id))
             (entry (plist-get (plist-get floor :speaking) :id)))
        (harness-call 'workspace/speech/claim id entry "desk")
        (harness-call 'workspace/speech/hold id)
        ;; The user is away far longer than a lease lasts.
        (let ((state (harness-workspace-speech--load id)))
          (dolist (item (plist-get state :entries))
            (when (equal entry (plist-get item :id))
              (setf (plist-get item :claimed-at) (- (float-time) 600)
                    (plist-get item :held-at) (- (float-time) 600))))
          (puthash id state harness-workspace-speech--table))
        (setq floor (harness-call 'workspace/speech id))
        (should (equal "One." (plist-get (plist-get floor :speaking) :text)))
        (should (equal "held" (plist-get (plist-get floor :speaking) :state)))
        (should (null (plist-get floor :recent)))))))

(ert-deftest harness-workspace-speech-resume-recovers-a-lost-holder ()
  "Words held by a client that is gone are not resumed by a stranger."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace))
                 (harness-workspace-speech-claim-seconds 30))
      (harness-call 'workspace/speech/enqueue id one "One." (list :node "n1"))
      (harness-call 'workspace/speech/enqueue id two "Two." (list :node "n2"))
      (let* ((floor (harness-call 'workspace/speech id))
             (entry (plist-get (plist-get floor :speaking) :id)))
        (harness-call 'workspace/speech/claim id entry "desk")
        (harness-call 'workspace/speech/hold id)
        (let ((state (harness-workspace-speech--load id)))
          (dolist (item (plist-get state :entries))
            (when (equal entry (plist-get item :id))
              (setf (plist-get item :claimed-at) (- (float-time) 600))))
          (puthash id state harness-workspace-speech--table))
        (setq floor (harness-call 'workspace/speech/resume id))
        (should (equal "Two." (plist-get (plist-get floor :speaking) :text)))
        (should (equal "Speaker lost" (plist-get (car (plist-get floor :recent)) :why)))
        (should (equal "One." (plist-get (car (plist-get floor :recent)) :text)))))))

(ert-deftest harness-workspace-speech-hold-round-trips-through-the-store ()
  "A client that reconnects finds the hold and the words where they were."
  (harness-workspace-speech-test-with
    (pcase-let* ((`(,id ,one ,two) (harness-workspace-speech-test-workspace)))
      (harness-call 'workspace/speech/enqueue id one "One." (list :node "n1"))
      (harness-call 'workspace/speech/enqueue id two "Two." (list :node "n2"))
      (let ((before (harness-call 'workspace/speech/hold id (list :played 7.0))))
        (clrhash harness-workspace-speech--table)
        (let ((after (harness-call 'workspace/speech id)))
          (should (equal (plist-get before :revision) (plist-get after :revision)))
          (should (plist-get after :hold))
          (should (equal "held" (plist-get (plist-get after :speaking) :state)))
          (should (= 7.0 (plist-get (plist-get after :speaking) :played)))
          (should (= 1 (length (plist-get after :waiting)))))))))

(provide 'harness-workspace-speech-test)
;;; harness-workspace-speech-test.el ends here
