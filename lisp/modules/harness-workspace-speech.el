;;; harness-workspace-speech.el --- The workspace's one speech floor: queue, solo, one speaker  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; A workspace has many threads, and while the user is away from the
;; screen they all want to say something.  They must not speak over one
;; another, and the user must be able to keep one of them talking while
;; the others wait.  This module is the one record of that: the
;; workspace's *speech floor*.
;;
;; It is the workspace's record, not a client's.  A phone, a desktop and
;; an Emacs all read the same floor over ACP, so no client keeps a
;; second queue and no client decides on its own whose turn it is:
;;
;;   `workspace/speech'           the floor as clients read it
;;   `workspace/speech/enqueue'   a thread has something to say
;;   `workspace/speech/claim'     this client will speak that entry
;;   `workspace/speech/advance'   the entry finished, failed or was stopped
;;   `workspace/speech/solo'      only this thread speaks, until `unsolo'
;;   `workspace/speech/unsolo'    every thread is eligible again
;;   `workspace/speech/hold'      stop speaking, keeping the playing words
;;   `workspace/speech/resume'    go on from where they stopped
;;   `workspace/speech/cancel'    drop an entry, a thread's entries or all
;;   `workspace/speech/clear'     forget the finished entries a client showed
;;   `workspace/speech/update'    turn the floor on or off for the workspace
;;
;; and every change is announced as `workspace/speech-changed (ID SPEECH)'.
;;
;; The rules, which the tests hold:
;;
;; - One entry speaks at a time.  FIFO by the time it arrived, then by
;;   id, so a restart does not reorder the queue.
;; - Enqueue is idempotent by `:node': two clients seeing the same
;;   assistant node, or one seeing it twice, make one entry, never two.
;; - `solo' does not stop a thread: the other threads keep working and
;;   their entries stay in `:waiting', marked `:held "Solo"'.  What solo
;;   stops is *speech*: an utterance of another thread that is playing
;;   yields at once (`:state "cancelled"', `:outcome "interrupted"',
;;   `:why "Solo"'), because soloing is how the user keeps that thread
;;   from being interrupted -- letting the other one finish is the one
;;   thing solo exists to prevent.  The soloed thread's own utterance is
;;   never interrupted by solo.
;; - `unsolo' releases only the head of the queue, so clearing solo is
;;   not a burst of speech.  A thread's entries do not replay: what was
;;   said is `:recent', never `:waiting' again.
;; - `hold' is the global pause, and the difference from solo is the
;;   point: solo *yields* another thread's utterance, hold *keeps* it.
;;   The words playing when the hold starts stay `:speaking' (state
;;   `held', with the seconds played), so taking an earbud out to answer
;;   someone and putting it back finds the same sentence where it was.
;;   Solo's `:held' names a waiting entry that solo keeps from starting;
;;   hold's `:held' names the floor itself, and a waiting entry under it
;;   carries `:why "Hold"'.  A hold and a solo are separate facts on one
;;   floor: `hold' with a solo keeps both, `unsolo' never clears the
;;   hold, `resume' never clears the solo, and `:waiting' under a hold is
;;   still the whole queue in the order it will be spoken.
;; - A thread that is deleted, or an episode whose thread is gone, has
;;   its entries cancelled with `:why "Thread removed"': visible in
;;   `:recent', skipped by the speaker.  A workspace with no threads is
;;   answered, never signalled.
;; - The queue is bounded (`harness-workspace-speech-queue-limit').  The
;;   oldest waiting entry is cancelled with `:why "Queue full"' and stays
;;   visible in `:recent'; a new arrival is never dropped silently.
;; - `:revision' only ever grows, and every change -- implicit ones
;;   included -- bumps it, so a client can drop a stale view.
;;
;; Who speaks.  The floor says *what* should be said; a client says it.
;; Two clients in the room would otherwise say it twice, so a client
;; claims the speaking entry before it synthesizes anything
;; (`workspace/speech/claim').  A claim is a lease: a client that dies
;; mid-utterance leaves it to expire
;; (`harness-workspace-speech-claim-seconds'), after which the entry is
;; cancelled `:why "Speaker lost"' and the floor moves on.  The device
;; and cross-client guarantees this can and cannot give are written in
;; docs/design/workspace-speech-queue.md; the honest summary is that the floor is one
;; record with one speaker, and that two clients which both claim in the
;; same instant are serialized by the harness, so exactly one of them
;; wins -- what no client can do is keep a claim it never reports back
;; from blocking the floor forever, which is the lease's job.
;;
;; The floor is a separate store file beside the workspace
;; (`workspaces/ID.speech.json'), so a workspace record and a speech
;; queue never overwrite each other and the workspace module needs no
;; change to carry it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-store)
(require 'harness-workspace)

(defvar harness-state-directory)

(defgroup harness-workspace-speech nil
  "The workspace's speech floor: one speaker, a queue and solo."
  :group 'harness-workspace
  :prefix "harness-workspace-speech-")

(defcustom harness-workspace-speech t
  "Whether a workspace episode's reply is offered to the speech floor.
When nil the floor still works; nothing is added to it by itself, and a
client may enqueue what it likes."
  :type 'boolean
  :group 'harness-workspace-speech)

(defcustom harness-workspace-speech-queue-limit 24
  "Most entries the floor keeps waiting at once.
The oldest waiting entry is cancelled, with `:why \"Queue full\"', when
another arrives; it stays visible in `:recent', never silently lost."
  :type 'integer
  :group 'harness-workspace-speech)

(defcustom harness-workspace-speech-recent-limit 8
  "Most finished entries the floor keeps for clients to show."
  :type 'integer
  :group 'harness-workspace-speech)

(defcustom harness-workspace-speech-claim-seconds 180
  "Seconds a client's claim on the speaking entry holds.
A client that dies mid-utterance leaves its claim behind; after this
long a floor that is read, or that another client claims, cancels the
entry `:why \"Speaker lost\"' and moves on.  It is a lease, not a
promise that audio keeps playing."
  :type 'number
  :group 'harness-workspace-speech)

(defcustom harness-workspace-speech-max-chars 8000
  "Most characters of one entry's text the floor keeps."
  :type 'integer
  :group 'harness-workspace-speech)

(defconst harness-workspace-speech--directory "workspaces"
  "Directory under the state directory that holds the floor files.")

(defvar harness-workspace-speech--table (make-hash-table :test 'equal)
  "Workspace id -> floor state plist, as last read or written.")

(defvar harness-workspace-speech--subscribed nil
  "Non-nil once the module subscribed to the harness's events.")

;;;; State

(defun harness-workspace-speech--file (id)
  "Return the floor file of workspace ID."
  (concat harness-workspace-speech--directory "/" id ".speech.json"))

(defun harness-workspace-speech--fresh ()
  "Return an empty floor."
  (list :revision 0 :solo nil :hold nil :entries nil :recent nil :counter 0 :enabled t))

(defun harness-workspace-speech--load (id)
  "Return the floor of workspace ID, reading it once.
The workspace itself must exist: a floor is a workspace's, and an
unknown id is the same error `workspace/get' gives."
  (unless (harness-call 'workspace/get id)
    (signal 'harness-error (list (format "No workspace %s" id))))
  (or (gethash id harness-workspace-speech--table)
      (let ((state (condition-case err
                       (harness-call 'store/load (harness-workspace-speech--file id))
                     (error
                      (harness-log 'warn "workspace-speech: cannot read %s: %s"
                                   id (harness-error-message err))
                      nil))))
        (setq state (if (and (listp state) (plist-get state :revision))
                        (harness-plist-merge (harness-workspace-speech--fresh) state)
                      (harness-workspace-speech--fresh)))
        (puthash id state harness-workspace-speech--table)
        state)))

(defun harness-workspace-speech--save (id state)
  "Write STATE as the floor of workspace ID and announce it.
The revision is bumped first: every change a client can see is a new
revision, an implicit one included."
  (let* ((state (plist-put (copy-sequence state) :revision
                           (1+ (or (plist-get state :revision) 0))))
         (state (plist-put state :workspace id)))
    (puthash id state harness-workspace-speech--table)
    (harness-call 'store/save (harness-workspace-speech--file id) state)
    (harness-emit 'workspace/speech-changed id (harness-workspace-speech--view id state))
    state))

(defun harness-workspace-speech--entries (state)
  "Return STATE's live entries, oldest first."
  (sort (copy-sequence (plist-get state :entries))
        (lambda (a b)
          (let ((ta (or (plist-get a :at) 0))
                (tb (or (plist-get b :at) 0)))
            (if (= ta tb)
                (string< (or (plist-get a :id) "") (or (plist-get b :id) ""))
              (< ta tb))))))

(defun harness-workspace-speech--entry (state id)
  "Return the live entry ID of STATE, or nil."
  (cl-find id (plist-get state :entries)
           :key (lambda (entry) (plist-get entry :id)) :test #'equal))

(defun harness-workspace-speech--by-node (state node)
  "Return the entry of STATE made for NODE, live or recent, or nil."
  (and (stringp node)
       (or (cl-find node (plist-get state :entries)
                    :key (lambda (entry) (plist-get entry :node)) :test #'equal)
           (cl-find node (plist-get state :recent)
                    :key (lambda (entry) (plist-get entry :node)) :test #'equal))))

(defun harness-workspace-speech--put-entry (state entry)
  "Put ENTRY into STATE's live entries, replacing the entry with its id."
  (let* ((entries (plist-get state :entries))
         (pos (cl-position (plist-get entry :id) entries
                           :key (lambda (item) (plist-get item :id)) :test #'equal)))
    (setf (plist-get state :entries)
          (if pos
              (progn (setcar (nthcdr pos entries) entry) entries)
            (append entries (list entry))))))

(defun harness-workspace-speech--drop-entry (state id)
  "Remove the live entry ID from STATE and return it."
  (let ((entry (harness-workspace-speech--entry state id)))
    (when entry
      (setf (plist-get state :entries)
            (cl-remove-if (lambda (item) (equal (plist-get item :id) id))
                          (plist-get state :entries))))
    entry))

(defun harness-workspace-speech--retire (state entry state-name outcome why)
  "Move ENTRY out of STATE's live entries.
STATE-NAME is the state it ends in (\"cancelled\" or \"failed\"), OUTCOME
distinguishes a finished utterance from one that yielded (\"interrupted\"),
and WHY is the stable, unlocalised reason a client shows.  A retired
entry is shown in `:recent' for a while and is never spoken again.
Return the entry."
  (let ((entry (plist-put (copy-sequence entry) :state (or state-name "cancelled"))))
    (setq entry (plist-put entry :outcome (or outcome state-name "cancelled")))
    (when why (setq entry (plist-put entry :why why)))
    (setq entry (plist-put entry :ended (float-time)))
    (harness-workspace-speech--drop-entry state (plist-get entry :id))
    (setf (plist-get state :recent)
          (cons entry (cl-remove-if (lambda (item)
                                      (equal (plist-get item :id) (plist-get entry :id)))
                                    (plist-get state :recent))))
    (when (> (length (plist-get state :recent)) harness-workspace-speech-recent-limit)
      (setf (plist-get state :recent)
            (seq-take (plist-get state :recent) harness-workspace-speech-recent-limit)))
    entry))

(defun harness-workspace-speech--cancel-entry (state entry &optional why)
  "Cancel live ENTRY of STATE with WHY, and return it."
  (if (equal (plist-get entry :state) "speaking")
      (harness-workspace-speech--retire state entry "cancelled" "interrupted"
                                        (or why "Interrupted"))
    (harness-workspace-speech--retire state entry "cancelled" "cancelled"
                                      (or why "Cancelled"))))

(defun harness-workspace-speech--speaking (state)
  "Return STATE's playing entry, or nil.
A held entry is not playing: it is `harness-workspace-speech--current'."
  (cl-find "speaking" (plist-get state :entries)
           :key (lambda (entry) (plist-get entry :state)) :test #'equal))

(defun harness-workspace-speech--current (state)
  "Return STATE's entry holding the floor: playing or held, or nil.
A held utterance keeps the floor -- the next entry waits for it -- which
is what makes a hold a pause rather than a stop."
  (cl-find-if (lambda (entry) (member (plist-get entry :state) '("speaking" "held")))
              (harness-workspace-speech--entries state)))

(defun harness-workspace-speech--eligible-p (state entry)
  "Non-nil when ENTRY may speak under STATE's solo."
  (let ((solo (plist-get state :solo)))
    (or (null solo)
        (equal solo (plist-get entry :thread)))))

;;;; Claim lease

(defun harness-workspace-speech--claim-expired-p (entry)
  "Non-nil when ENTRY's claim is too old to be believed."
  (let ((at (plist-get entry :claimed-at)))
    (and (numberp at)
         (> (- (float-time) at) harness-workspace-speech-claim-seconds))))

(defun harness-workspace-speech--reclaim (id state)
  "Cancel STATE's speaking entry when its claim expired.
Return non-nil when the state changed.  A client that died mid-utterance
must not hold the floor for good."
  ;; A held floor is the user's pause, not a dead speaker: its claim is
  ;; not aged out while they are away from the screen.
  (when-let* ((entry (harness-workspace-speech--speaking state))
              ((not (plist-get state :hold)))
              ((plist-get entry :claimed))
              ((harness-workspace-speech--claim-expired-p entry)))
    (harness-workspace-speech--retire state entry "failed" "failed" "Speaker lost")
    (harness-workspace-speech--promote state)
    (harness-workspace-speech--save id state)
    t))

;;;; Promotion

(defun harness-workspace-speech--promote (state)
  "Make the head eligible queued entry of STATE speak.
Nothing happens while something speaks or the floor is held, or when
solo holds everything: one entry speaks at a time, and unsolo is what
releases the others while resume releases a held floor."
  (unless (or (harness-workspace-speech--speaking state)
              (plist-get state :hold))
    (let ((next (cl-find-if (lambda (entry)
                              (and (equal (plist-get entry :state) "queued")
                                   (harness-workspace-speech--eligible-p state entry)))
                            (harness-workspace-speech--entries state))))
      (when next
        (harness-workspace-speech--put-entry
         state (plist-put (copy-sequence next) :state "speaking"))))))

;;;; Enqueue

(defun harness-workspace-speech--clip (text)
  "Return TEXT clipped to what the floor keeps."
  (let ((text (string-trim (or text ""))))
    (if (> (length text) harness-workspace-speech-max-chars)
        (concat (substring text 0 harness-workspace-speech-max-chars) "…")
      text)))

(defun harness-workspace-speech--preview (text)
  "Return a one-line preview of TEXT."
  (let ((line (car (split-string (or text "") "\n" t))))
    (when (> (length line) 120) (setq line (concat (substring line 0 119) "…")))
    (or line "")))

(defun harness-workspace-speech--thread-record (workspace thread)
  "Return THREAD of WORKSPACE, or nil."
  (cl-find thread (plist-get workspace :threads)
           :key (lambda (item) (plist-get item :id)) :test #'equal))

(defun harness-workspace-speech--enqueue (id thread text &optional opts)
  "Offer TEXT from THREAD to workspace ID's floor.
OPTS may give `:node' (the assistant node the words came from, which
makes a repeated offer the same entry), `:session' and `:source'.
Return the entry: the one already there for `:node', or the new one."
  (let* ((state (harness-workspace-speech--load id))
         (workspace (harness-call 'workspace/get id))
         (record (harness-workspace-speech--thread-record workspace thread))
         (node (plist-get opts :node))
         (text (harness-workspace-speech--clip text)))
    (unless record
      (signal 'harness-error (list (format "No thread %s in workspace %s" thread id))))
    (or (harness-workspace-speech--by-node state node)
        (when (stringp text)
          (let* ((counter (1+ (or (plist-get state :counter) 0)))
                 (entry (list :id (format "sp-%s-%d" (harness-short-id 8) counter)
                              :workspace id
                              :thread thread
                              :thread-title (or (plist-get record :title) "Thread")
                              :session (or (plist-get opts :session) (plist-get record :live))
                              :node node
                              :source (or (plist-get opts :source) "reply")
                              :text text
                              :preview (harness-workspace-speech--preview text)
                              :state "queued"
                              :at (float-time)
                              :why nil
                              :outcome nil)))
            (setf (plist-get state :counter) counter)
            (when (string-empty-p text)
              (setq entry nil))
            (when entry
              ;; Bound the waiting queue: the oldest waiting entry goes,
              ;; visibly, so a long silence never grows without limit.
              (let ((waiting (cl-remove-if-not
                              (lambda (item) (equal (plist-get item :state) "queued"))
                              (harness-workspace-speech--entries state))))
                (while (>= (length waiting) harness-workspace-speech-queue-limit)
                  (let ((oldest (car waiting)))
                    (setq waiting (cdr waiting))
                    (harness-workspace-speech--retire state oldest "cancelled" "cancelled"
                                                      "Queue full"))))
              (harness-workspace-speech--put-entry state entry)
              (harness-workspace-speech--promote state)
              (harness-workspace-speech--save id state)
              ;; Return the live copy: promotion may have made it speak.
              (or (harness-workspace-speech--entry state (plist-get entry :id)) entry)))))))

;;;; The floor as clients read it

(defun harness-workspace-speech--decorate (state entry)
  "Return ENTRY of STATE with what a client shows about it now.
`:held' names why a waiting entry is not speaking: solo does not stop a
thread, it holds its words, and the entry keeps its place."
  (let* ((solo (plist-get state :solo))
         (hold (plist-get state :hold))
         (solo-held (and (not (harness-workspace-speech--eligible-p state entry))
                         (not (null solo))))
         (entry (copy-sequence entry)))
    (cond (solo-held (plist-put entry :held "Solo"))
          (hold (plist-put entry :why "Hold"))
          (t entry))))

(defun harness-workspace-speech--view (id state)
  "Return STATE, the floor of workspace ID, as clients read it.
`:active' is the thread holding the floor -- the speaker, or the soloed
thread when nothing speaks -- and `:solo-title' names it.  The floor of
a workspace whose threads were removed is answered normally, with the
removed thread's entries cancelled in `:recent'."
  (let* ((workspace (ignore-errors (harness-call 'workspace/get id)))
         (threads (plist-get workspace :threads))
         (title (lambda (thread)
                  (or (plist-get (cl-find thread threads
                                          :key (lambda (item) (plist-get item :id))
                                          :test #'equal)
                                 :title)
                      "Thread")))
         (entries (harness-workspace-speech--entries state))
         (speaking (cl-find-if (lambda (entry)
                                 (member (plist-get entry :state) '("speaking" "held")))
                               entries))
         (waiting (cl-remove-if-not (lambda (entry)
                                      (equal (plist-get entry :state) "queued"))
                                    entries))
         (solo (plist-get state :solo))
         (hold (plist-get state :hold)))
    (list :workspace id
          :revision (or (plist-get state :revision) 0)
          :enabled (if (plist-member state :enabled) (plist-get state :enabled) t)
          ;; The global hold keeps the playing words; `:held' names it so
          ;; a client says why nothing advances.
          :hold (and hold t)
          :held (and hold t)
          :hold-at (and hold (numberp hold) hold)
          :solo solo
          :solo-title (and solo (funcall title solo))
          :speaking (and speaking
                          (plist-put (copy-sequence speaking) :thread-title
                                     (funcall title (plist-get speaking :thread))))
          :waiting (mapcar (lambda (entry)
                             (plist-put (harness-workspace-speech--decorate state entry)
                                        :thread-title
                                        (funcall title (plist-get entry :thread))))
                           waiting)
          :active (or (and speaking (plist-get speaking :thread)) solo)
          :count (length waiting)
          :recent (mapcar (lambda (entry)
                            (plist-put (copy-sequence entry) :thread-title
                                       (funcall title (plist-get entry :thread))))
                          (plist-get state :recent)))))

;;;; Methods

(harness-defmethod workspace/speech (id)
  "Return the speech floor of workspace ID.
One entry speaks at a time (`:speaking'); `:waiting' is the queue in the
order it will be spoken, `:solo' is the thread whose speech holds the
others, `:active' the thread holding the floor, and `:recent' what was
spoken, failed or was cancelled.  Reading the floor recovers a speaker
that died: a claim lease that expired is cancelled `:why \"Speaker
lost\"' and the next entry is released."
  (let ((state (harness-workspace-speech--load id)))
    (harness-workspace-speech--reclaim id state)
    (harness-workspace-speech--view id state)))

(harness-defmethod workspace/speech/enqueue (id thread text &optional opts)
  "Offer TEXT from THREAD to the floor of workspace ID.
Return the entry, and `:revision' of the floor as it is after the
offer.  OPTS `:node' makes the offer idempotent: the same assistant node
offered twice is one entry.  `:session' and `:source' are provenance."
  (let* ((entry (harness-workspace-speech--enqueue id thread text opts))
         ;; The floor as it is now: the offer may have made it speak.
         (after (harness-workspace-speech--load id)))
    (list :entry entry
          :revision (or (plist-get after :revision) 0)
          :floor (harness-workspace-speech--view id after))))

(harness-defmethod workspace/speech/claim (id entry &optional client)
  "Claim the speaking ENTRY of workspace ID for CLIENT.
A client claims before it synthesizes anything, so two clients in the
room say it once.  Return `:claimed' non-nil when CLIENT holds it now --
it already did, it just took it, or the entry needs no claim; nil when
another client holds a live claim, so this one must stay silent.  The
answer carries the floor as it is."
  (let* ((state (harness-workspace-speech--load id))
         (live (and (stringp entry) (harness-workspace-speech--entry state entry)))
         (speaking (harness-workspace-speech--speaking state))
         (client (or client "client")))
    (cond
     ((and (plist-get state :hold)
           (not (and live (member (plist-get live :state) '("held" "speaking")))))
      ;; Nothing starts while the floor is held: the words wait, visible.
      (list :claimed nil :applied nil :held t
            :floor (harness-workspace-speech--view id state)))
     ((not (and live (equal (plist-get live :state) "speaking")))
      ;; A stale claim: the entry finished or yielded meanwhile.
      (list :claimed nil :applied nil :floor (harness-workspace-speech--view id state)))
     ((null (plist-get live :claimed))
      (harness-workspace-speech--put-entry
       state (plist-put (plist-put (copy-sequence live) :claimed client)
                        :claimed-at (float-time)))
      (let ((state (harness-workspace-speech--save id state)))
        (list :claimed t :applied t :client client
              :floor (harness-workspace-speech--view id state))))
     ((equal (plist-get live :claimed) client)
      (harness-workspace-speech--put-entry
       state (plist-put (copy-sequence live) :claimed-at (float-time)))
      (list :claimed t :applied t :client client
            :floor (harness-workspace-speech--view id (harness-workspace-speech--save id state))))
     ((harness-workspace-speech--claim-expired-p live)
      ;; The holder is gone; the claim is this client's.
      (harness-workspace-speech--retire state live "failed" "failed" "Speaker lost")
      (harness-workspace-speech--promote state)
      (let ((state (harness-workspace-speech--save id state)))
        (list :claimed nil :applied nil :recovered t :floor (harness-workspace-speech--view id state))))
     ((and speaking (not (equal (plist-get speaking :id) entry)))
      (list :claimed nil :applied nil :floor (harness-workspace-speech--view id state)))
     (t
      (list :claimed nil :applied nil :holder (plist-get live :claimed)
            :floor (harness-workspace-speech--view id state))))))

(harness-defmethod workspace/speech/advance (id entry &optional outcome why)
  "Finish the speaking ENTRY of workspace ID with OUTCOME.
OUTCOME is \"finished\", \"failed\" or \"cancelled\"; WHY is the one line a
client shows for a failure or a cancellation.  Only the entry that is
speaking now is advanced: a report about one that already yielded is
answered `:applied nil' with the floor as it is, so a stale report never
moves the next entry.  The next entry is released at once -- one only,
and none while solo holds it."
  (let* ((state (harness-workspace-speech--load id))
         (outcome (let ((value (if (symbolp outcome) (symbol-name outcome) outcome)))
                    (if (member value '("finished" "failed" "cancelled"))
                        value "finished")))
         (live (and (stringp entry) (harness-workspace-speech--entry state entry)))
         (applied (and live (equal (plist-get live :state) "speaking"))))
    (when applied
      (harness-workspace-speech--retire state live
                                        (if (equal outcome "failed") "failed" "cancelled")
                                        outcome why)
      (harness-workspace-speech--promote state)
      (let ((state (harness-workspace-speech--save id state)))
        (list :applied t :outcome outcome :floor (harness-workspace-speech--view id state))))
    (unless applied
      (list :applied nil :outcome outcome :floor (harness-workspace-speech--view id state)))))

(harness-defmethod workspace/speech/solo (id thread)
  "Give the floor of workspace ID to THREAD alone, until `unsolo'.
The other threads keep working and their entries stay in `:waiting',
held: they are not cancelled, not dropped and not muted.  An utterance
of another thread is interrupted at once -- that is what solo is for --
and the soloed thread's utterance always finishes.  The next waiting
entry is released only when the soloed thread has none, so solo is not a
second stream of speech."
  (let* ((state (harness-workspace-speech--load id))
         (workspace (harness-call 'workspace/get id))
         (record (harness-workspace-speech--thread-record workspace thread)))
    (unless record
      (signal 'harness-error (list (format "No thread %s in workspace %s" thread id))))
    (setf (plist-get state :solo) thread)
    (when-let* ((speaking (harness-workspace-speech--speaking state))
                ((not (equal (plist-get speaking :thread) thread)))
                ;; A held utterance is frozen, not playing, and the user
                ;; paused in the middle of it: solo changes what starts
                ;; next, and the frozen words finish after the resume
                ;; rather than being thrown away by a hold.
                ((not (plist-get state :hold))))
      (harness-workspace-speech--retire state speaking "cancelled" "interrupted" "Solo"))
    (harness-workspace-speech--promote state)
    (harness-workspace-speech--view id (harness-workspace-speech--save id state))))

(harness-defmethod workspace/speech/unsolo (id)
  "Let every thread of workspace ID be spoken again.
Nothing is interrupted: a speaking entry finishes, and the next one is
released when it does, one at a time.  Entries that waited through solo
keep their place, so clearing solo is not a burst."
  (let ((state (harness-workspace-speech--load id)))
    (setf (plist-get state :solo) nil)
    (harness-workspace-speech--promote state)
    (harness-workspace-speech--view id (harness-workspace-speech--save id state))))


;;;; The global hold

(defun harness-workspace-speech--held-entry (state)
  "Return STATE's own utterance while the floor is held, or nil.
It is the entry frozen by the hold, not a queue head that never started."
  (when (plist-get state :hold)
    (cl-find "held" (plist-get state :entries)
             :key (lambda (entry) (plist-get entry :state)) :test #'equal)))

(harness-defmethod workspace/speech/hold (id &optional opts)
  "Hold the floor of workspace ID: nothing starts speaking until `resume'.
The utterance playing now is *kept*, not yielded: it stays `:speaking'
with state `held' and the seconds of it already played, so the same
words are where the user left them when they come back.  New arrivals
wait in `:waiting', visible and in order, and the threads keep working.
OPTS `:played' is the seconds the client had played when it stopped, and
`:entry' is the entry it had; a hold with no speaking entry holds the
queue alone.  Holding twice keeps one hold and one position."
  (let* ((state (harness-workspace-speech--load id))
         (entry-id (plist-get opts :entry))
         (played (plist-get opts :played))
         (speaking (harness-workspace-speech--speaking state)))
    (setf (plist-get state :hold) (or (plist-get state :hold) (float-time)))
    (when (and speaking
               (or (null entry-id) (equal entry-id (plist-get speaking :id))))
      (let ((held (plist-put (copy-sequence speaking) :state "held")))
        (when (numberp played)
          (setq held (plist-put held :played (max 0 played))))
        (setq held (plist-put held :held-at (float-time)))
        ;; The same client keeps its claim through the pause: its lease
        ;; starts again when the words do, not when they stopped.
        (when (plist-get held :claimed)
          (setq held (plist-put held :claimed-at (float-time))))
        ;; The position is kept on the entry, so a client that reconnects
        ;; while the floor is held still finds where the words stopped.
        (harness-workspace-speech--put-entry state held)))
    (harness-workspace-speech--view id (harness-workspace-speech--save id state))))

(defun harness-workspace-speech--unplayed (entry)
  "Return ENTRY without the position it stopped at.
A client that starts the words over has nothing to seek to, and a stale
`:played' would make it pick up in the middle of words it never heard."
  (let (out)
    (cl-loop for (key value) on entry by #'cddr
             unless (memq key '(:played :held-at))
             do (setq out (plist-put out key value)))
    out))

(harness-defmethod workspace/speech/resume (id &optional opts)
  "Let the held floor of workspace ID speak again, one entry at a time.
A held utterance is released where it stopped (its client resumes from
`:played'); with none held, the head of the waiting queue starts.  One
entry only, so a resume is never a burst, and a solo still holds the
other threads."
  (let* ((state (harness-workspace-speech--load id))
         (held (harness-workspace-speech--held-entry state)))
    (setf (plist-get state :hold) nil)
    (when (and held (harness-workspace-speech--claim-expired-p held))
      ;; The client that held the words is gone.  They are not replayed
      ;; by a stranger: they are lost, visibly, and the next speaks.
      (harness-workspace-speech--retire state held "failed" "failed" "Speaker lost")
      (setq held nil))
    (cond
     ((and held (plist-get opts :restart))
      ;; A client that cannot seek starts the words over rather than
      ;; leaving them unsaid: the entry goes back to the queue, at its
      ;; place, and is promoted like any other.
      (harness-workspace-speech--put-entry
       state (harness-workspace-speech--unplayed
              (plist-put (harness-workspace-speech--drop-entry
                          state (plist-get held :id))
                         :state "queued"))))
     (held
      ;; The words go on from where they stopped: the same entry is
      ;; playing again, and its client, which kept its claim through the
      ;; pause, seeks to `:played'.
      (let ((resumed (plist-put (copy-sequence held) :state "speaking")))
        (when (plist-get resumed :claimed)
          (setq resumed (plist-put resumed :claimed-at (float-time))))
        (harness-workspace-speech--put-entry state resumed))))
    (harness-workspace-speech--promote state)
    (harness-workspace-speech--view id (harness-workspace-speech--save id state))))

(harness-defmethod workspace/speech/cancel (id &optional target)
  "Drop entries of workspace ID from the floor.
TARGET nil cancels everything, speaking included; a string cancels that
entry, or every entry of that thread.  Cancelled entries stay in
`:recent' with `:why': nothing is lost silently, and nothing cancelled
is spoken again."
  (let* ((state (harness-workspace-speech--load id))
         (entries (harness-workspace-speech--entries state))
         (doomed (cond ((null target) entries)
                       ((eq target t) entries)
                       ((stringp target)
                        (cl-remove-if-not
                         (lambda (entry)
                           (or (equal (plist-get entry :id) target)
                               (equal (plist-get entry :thread) target)))
                         entries))
                       (t nil))))
    ;; The hold is the user's own pause, not a property of the queue:
    ;; cancelling what waits leaves it in place, so nothing starts
    ;; speaking by surprise after a cancel.
    (when (plist-get state :solo)
      ;; Cancelling the soloed thread's entries, or everything, leaves
      ;; no reason to hold the others.
      (when (or (null target) (eq target t)
                (and (stringp target)
                     (or (equal (plist-get state :solo) target)
                         (cl-some (lambda (entry) (equal (plist-get entry :id) target)) doomed))))
        (setf (plist-get state :solo) nil)))
    (dolist (entry doomed)
      (harness-workspace-speech--cancel-entry state entry))
    (harness-workspace-speech--promote state)
    (harness-workspace-speech--view id (harness-workspace-speech--save id state))))

(harness-defmethod workspace/speech/clear (id)
  "Forget the finished entries of workspace ID's floor.
`:waiting' and `:speaking' are untouched; `:recent' is emptied, so a
client's history is cleared rather than the queue."
  (let ((state (harness-workspace-speech--load id)))
    (setf (plist-get state :recent) nil)
    (harness-workspace-speech--view id (harness-workspace-speech--save id state))))

(harness-defmethod workspace/speech/update (id &rest plist)
  "Change the floor of workspace ID.  PLIST may set `:enabled'.
A workspace whose floor is disabled keeps its queue; nothing is added to
it by itself, so a reply is not announced."
  (let ((state (harness-workspace-speech--load id)))
    (when (plist-member plist :enabled)
      (setf (plist-get state :enabled) (harness-json-true-p (plist-get plist :enabled))))
    (harness-workspace-speech--view id (harness-workspace-speech--save id state))))

;;;; Following the workspace's replies

(defun harness-workspace-speech--floor-enabled-p (id)
  "Non-nil when workspace ID's floor takes replies by itself."
  (let ((state (harness-workspace-speech--load id)))
    (and (if (plist-member state :enabled) (plist-get state :enabled) t)
         harness-workspace-speech)))

(defun harness-workspace-speech--offer-node (session-id node transient)
  "Offer NODE of SESSION-ID to its workspace's floor, once final.
The final write of an assistant node is what the user hears; a streaming
delta is not offered, so a long answer is one entry, not a thousand."
  (when (and (not transient)
             (eq (harness-workspace-speech--node-kind node) 'assistant))
    (let* ((ext (harness-workspace--episode-p session-id))
           (id (plist-get ext :workspace))
           (thread (plist-get ext :thread))
           (text (harness-workspace-speech--clip (plist-get node :content)))
           (node-id (plist-get node :id)))
      (when (and id thread (stringp text) (not (string-blank-p text))
                 (harness-workspace-speech--floor-enabled-p id))
        (condition-case err
            (harness-workspace-speech--enqueue
             id thread text (list :node node-id :session session-id :source "reply"))
          (error
           (harness-log 'warn "workspace-speech: cannot offer %s: %s"
                        node-id (harness-error-message err))))))))

(defun harness-workspace-speech--node-kind (node)
  "Return NODE's kind as a symbol, or nil."
  (let ((kind (plist-get node :kind)))
    (cond ((symbolp kind) kind)
          ((stringp kind) (intern kind))
          (t nil))))

(defun harness-workspace-speech--on-node-updated (session-id node transient)
  "Offer the final assistant NODE of SESSION-ID to its workspace floor."
  (harness-workspace-speech--offer-node session-id node transient))

(defun harness-workspace-speech--on-thread-changed (id thread)
  "Cancel the floor entries of a thread deleted from workspace ID.
The entries stay in `:recent' with `:why \"Thread removed\"': a client
shows what was skipped rather than pretending it never arrived."
  (when (and (stringp id) (listp thread) (plist-get thread :deleted)
             (gethash id harness-workspace-speech--table))
    (let* ((state (harness-workspace-speech--load id))
           (thread-id (plist-get thread :id))
           (doomed (cl-remove-if-not
                    (lambda (entry) (equal (plist-get entry :thread) thread-id))
                    (harness-workspace-speech--entries state))))
      (when (or doomed (equal (plist-get state :solo) thread-id))
        (when (equal (plist-get state :solo) thread-id)
          (setf (plist-get state :solo) nil))
        (dolist (entry doomed)
          (harness-workspace-speech--retire state entry "cancelled" "cancelled"
                                            "Thread removed"))
        (harness-workspace-speech--promote state)
        (harness-workspace-speech--save id state)))))

(defun harness-workspace-speech--on-workspace-deleted (id)
  "Forget the floor of deleted workspace ID."
  (when (stringp id)
    (remhash id harness-workspace-speech--table)
    (harness-call 'store/delete (harness-workspace-speech--file id))))

;;;; Module

(defun harness-workspace-speech--install-acp ()
  "Expose the floor's methods and event to ACP clients."
  (when (boundp 'harness-acp-extra-events)
    (add-to-list 'harness-acp-extra-events 'workspace/speech-changed)))

(defun harness-workspace-speech--init ()
  "Follow the workspace's replies and expose the floor over ACP."
  (harness-workspace-speech--install-acp)
  (with-eval-after-load 'harness-acp (harness-workspace-speech--install-acp))
  (unless harness-workspace-speech--subscribed
    (setq harness-workspace-speech--subscribed t)
    (harness-on 'session/node-updated #'harness-workspace-speech--on-node-updated)
    (harness-on 'workspace/thread-changed #'harness-workspace-speech--on-thread-changed)
    (harness-on 'workspace/deleted #'harness-workspace-speech--on-workspace-deleted)))

(defun harness-workspace-speech--shutdown ()
  "Stop following the workspace's replies."
  (when harness-workspace-speech--subscribed
    (setq harness-workspace-speech--subscribed nil)
    (harness-off (cons 'session/node-updated #'harness-workspace-speech--on-node-updated))
    (harness-off (cons 'workspace/thread-changed #'harness-workspace-speech--on-thread-changed))
    (harness-off (cons 'workspace/deleted #'harness-workspace-speech--on-workspace-deleted))))

(harness-declare-event 'workspace/speech-changed
  "(ID SPEECH) when a workspace's speech floor changed.
SPEECH is the floor as `workspace/speech' answers it, so a client draws
the change without reading it again.")

(harness-define-module 'workspace-speech
  :doc "The workspace's speech floor: one speaker, a visible queue and solo."
  :requires '(store workspace)
  :init #'harness-workspace-speech--init
  :shutdown #'harness-workspace-speech--shutdown)

(provide 'harness-workspace-speech)
;;; harness-workspace-speech.el ends here
