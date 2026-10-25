;;; harness-slots.el --- At most so many at once, the rest wait their turn  -*- lexical-binding: t; -*-

;;; Commentary:

;; Some work is held to so many at a time, and whatever comes while they
;; are all taken waits its turn: the calls of the tools that start
;; processes (see tool-slots), the requests that title tasks (see
;; tasks).  This library is that rule once, so that none of them keeps a
;; count and a line of its own.
;;
;; A pool (`harness-slots-create') allows its limit of holders at once.
;; `harness-slots-acquire' asks for a slot and returns a promise of a
;; ticket, the function that gives the slot back: the promise resolves
;; at once while the pool has room, and otherwise when a slot is given
;; back to it.  A ticket gives its slot back once, however often it is
;; called, so a holder that is done in two ways -- its result and then
;; its timeout, say -- never frees a slot it no longer holds.
;;
;; The waiters go oldest first.  A pool made with a rank serves them by
;; it instead: the rank is a function of the DATA a waiter asked with,
;; the highest rank takes the next slot, the oldest of those first, and
;; ranks are read again whenever a slot frees, so a waiter whose rank
;; rose while it waited moves up the line.  DATA is whatever the asker
;; wants known of its place in the line -- the session a call serves, so
;; that the session's priority ranks it -- and `harness-slots-waiters'
;; lists it.
;;
;; The limit is a number, or a function of no arguments returning one,
;; called whenever the limit matters, so it can change while the pool is
;; in use.  A limit that rose starts nobody by itself: whoever raised it
;; calls `harness-slots-admit', which starts the waiters that now fit
;; (the next asker or giver-back would too).  A limit that fell stops no
;; holder; no waiter starts until the holders are under it again.
;;
;; A pool also notes who is using it, for a view of that: each holder
;; with the DATA it asked with and when it took its slot
;; (`harness-slots-holders'), and the waiters in the order they will be
;; served, with how long each has waited (`harness-slots-line').  That is
;; a record kept beside the count, not a part of it: the count of slots
;; held, which the limit is held to, is what it always was, and nothing
;; here changes who is served or when.
;;
;; A pool is plain state in the process that makes it, with no timer and
;; no module of its own; the library defines no macros, so a change to
;; it does not recompile the modules (`harness--library-files').  A
;; reload keeps the pools that exist, made by the code before it; so what
;; the pool did not have then -- the holders -- is not a slot of its
;; structure, which an old pool lacks and would signal for, but a table
;; beside it, which an old pool simply has no entry in.

;;; Code:

(require 'cl-lib)
(require 'harness-core)

(cl-defstruct (harness-slots--pool (:constructor harness-slots--make-pool)
                                   (:copier nil))
  limit                  ; an integer, or a function of no arguments returning one
  rank                   ; nil, or a function of a waiter's DATA returning a number
  (running 0)            ; how many hold a slot
  waiters)               ; plists (:data DATA :promise PROMISE :asked TIME), oldest first

(defvar harness-slots--holders (make-hash-table :test 'eq :weakness 'key)
  "Pool -> who holds its slots: plists (:data DATA :started TIME), oldest first.
Beside the pools rather than in them (see the commentary), and weak, so
a pool nobody uses any more takes its record with it.  A pool with no
holder has no entry.")

(cl-defun harness-slots-create (&key limit rank)
  "Return a pool of slots that allows LIMIT holders at once.
LIMIT is an integer, or a function of no arguments that returns one
and is called whenever the limit matters, so it can change.  RANK is
nil, to serve the waiters oldest first, or a function of the DATA a
waiter asked with (see `harness-slots-acquire') that returns a number:
the highest rank is served first, the oldest of those first, and ranks
are read again whenever a slot frees.  A rank that is no number counts
as 0."
  (unless (or (integerp limit) (functionp limit))
    (signal 'wrong-type-argument (list 'integer-or-function-p limit)))
  (unless (or (null rank) (functionp rank))
    (signal 'wrong-type-argument (list 'functionp rank)))
  (harness-slots--make-pool :limit limit :rank rank))

;;;; What a pool holds

(defun harness-slots-limit (pool)
  "Return how many holders POOL allows at once, as its limit says now."
  (let ((limit (harness-slots--pool-limit pool)))
    (if (functionp limit) (funcall limit) limit)))

(defun harness-slots-running (pool)
  "Return how many hold a slot of POOL."
  (harness-slots--pool-running pool))

(defun harness-slots-waiting (pool)
  "Return how many wait for a slot of POOL."
  (length (harness-slots--pool-waiters pool)))

(defun harness-slots-waiters (pool)
  "Return the DATA of each that waits for a slot of POOL, oldest first.
That is what `harness-slots-acquire' was given, in the order they asked,
not the order they will be served in when the pool has a rank
\(`harness-slots-line' lists that)."
  (mapcar (lambda (waiter) (plist-get waiter :data))
          (harness-slots--pool-waiters pool)))

(defun harness-slots-holders (pool)
  "Return who holds a slot of POOL, the one that has held it longest first.
Each is a plist (:data DATA :started TIME): DATA is what the holder asked
with (`harness-slots-acquire') and TIME, a float time, when the slot was
given to it -- when it asked, if it did not have to wait.  A holder
leaves the list when its ticket gives the slot back, and every holder
when the pool is flushed (`harness-slots-flush'), which counts no one as
holding a slot.  The plists are copies: changing one changes nothing in
POOL."
  (mapcar #'copy-sequence (gethash pool harness-slots--holders)))

(defun harness-slots-line (pool)
  "Return the waiters of POOL in the order they would be served now.
That is the order a slot that came free would be given out in: the
highest rank first, and among equal ranks the one that asked first
\(`harness-slots-create'), where `harness-slots-waiters' lists them as
they asked.  Each is a plist (:data DATA :asked TIME :rank RANK): DATA is
what the waiter asked with, TIME, a float time, when it began to wait --
nil for a waiter that began before the pool noted it -- and RANK what
the pool's rank function says of DATA now, 0 for a pool without one.
The ranks are read now, as they are whenever a slot frees."
  (cl-stable-sort
   (mapcar (lambda (waiter)
             (list :data (plist-get waiter :data)
                   :asked (plist-get waiter :asked)
                   :rank (harness-slots--rank pool waiter)))
           (harness-slots--pool-waiters pool))
   #'> :key (lambda (entry) (plist-get entry :rank))))

;;;; Giving slots out

(defun harness-slots--rank (pool waiter)
  "Return the rank of WAITER, a plist of POOL's line, as it is now.
That is what POOL's rank function says of WAITER's DATA, 0 when it says
no number, and 0 for a pool without one."
  (let* ((rank (harness-slots--pool-rank pool))
         (value (and rank (funcall rank (plist-get waiter :data)))))
    (if (numberp value) value 0)))

(defun harness-slots--next (pool)
  "Return the waiter of POOL that takes the next free slot.
Without a rank function that is the oldest.  With one it is the highest
ranked, the oldest of those first: the line is in the order the waiters
came, so the first of the highest rank is the oldest."
  (let* ((waiters (harness-slots--pool-waiters pool))
         (best (car waiters)))
    (when (harness-slots--pool-rank pool)
      (let ((best-rank (harness-slots--rank pool best)))
        (dolist (waiter (cdr waiters))
          (let ((rank (harness-slots--rank pool waiter)))
            (when (> rank best-rank)
              (setq best waiter best-rank rank))))))
    best))

(defun harness-slots--ticket (pool &optional holder)
  "Return the function that gives one slot of POOL back, once.
HOLDER is the entry of `harness-slots-holders' that goes with the slot:
the holder is dropped from the list as the slot goes back, before the
next waiter starts.  A slot that is not counted -- one a flush gave a
waiter -- has none."
  (let ((given nil))
    (lambda ()
      (unless given
        (setq given t)
        (harness-slots--drop pool holder)
        (harness-slots--give pool)))))

(defun harness-slots--grant (pool data)
  "Count a slot of POOL as taken by an asker with DATA, and return its ticket.
The asker is noted among the holders with the time it took the slot."
  (cl-incf (harness-slots--pool-running pool))
  (let ((holder (list :data data :started (float-time))))
    (puthash pool (nconc (gethash pool harness-slots--holders) (list holder))
             harness-slots--holders)
    (harness-slots--ticket pool holder)))

(defun harness-slots--drop (pool holder)
  "Take HOLDER, an entry of POOL's holders, out of them; nil is no holder.
A holder POOL does not list -- the pool was flushed since -- is no matter."
  (when holder
    (if-let* ((rest (delq holder (gethash pool harness-slots--holders))))
        (puthash pool rest harness-slots--holders)
      (remhash pool harness-slots--holders))))

(defun harness-slots--give (pool)
  "Give one slot of POOL back and start the next waiter, if one waits."
  (setf (harness-slots--pool-running pool)
        (max 0 (1- (harness-slots--pool-running pool))))
  (harness-slots-admit pool))

(defun harness-slots-admit (pool)
  "Start the waiters of POOL while it has room.
They go by rank, the oldest first among equals (`harness-slots-create').
Whoever raises POOL's limit while some wait calls this, so they start
without waiting for a holder to give a slot back.  The pool is brought
up to date before each waiter is told, so what a waiter does when it
starts, asking or giving back a slot, finds it as it should be."
  (while (and (harness-slots--pool-waiters pool)
              (< (harness-slots--pool-running pool) (harness-slots-limit pool)))
    (let ((waiter (harness-slots--next pool)))
      (setf (harness-slots--pool-waiters pool)
            (delq waiter (harness-slots--pool-waiters pool)))
      (harness-resolve (plist-get waiter :promise)
                       (harness-slots--grant pool (plist-get waiter :data))))))

(defun harness-slots-acquire (pool &optional data)
  "Return a promise of a ticket for a slot of POOL.
The ticket is a function of no arguments that gives the slot back, once:
call it when the work the slot was for is done, however it ended.  The
promise resolves at once while POOL has room, and otherwise when a slot
is given back to it, to the waiter that comes first by rank, the oldest
first among equals (`harness-slots-create').  DATA is what the asker
wants known of its place in the line: POOL's rank function is called
with it, and `harness-slots-waiters' lists it.  Those already waiting
that room has opened for, because the limit rose and nobody admitted
them yet, start before this asker does."
  (harness-slots-admit pool)
  (if (< (harness-slots--pool-running pool) (harness-slots-limit pool))
      (harness-resolved (harness-slots--grant pool data))
    (let ((promise (harness-make-promise)))
      (setf (harness-slots--pool-waiters pool)
            (nconc (harness-slots--pool-waiters pool)
                   (list (list :data data :promise promise :asked (float-time)))))
      promise)))

(defun harness-slots-flush (pool)
  "Let every waiter of POOL run now, and count no one as holding a slot.
What a pool does when its work is given up: nobody waits any longer, the
waiters are started oldest first, and the count of slots held goes back
to 0, so the waiters hold tickets of slots that are not counted.  The
holders are forgotten with the count (`harness-slots-holders'), those
the waiters became included.  The tickets handed out before still work;
giving a slot back never takes the count below 0."
  (let ((waiters (harness-slots--pool-waiters pool)))
    (setf (harness-slots--pool-waiters pool) nil
          (harness-slots--pool-running pool) 0)
    (remhash pool harness-slots--holders)
    (dolist (waiter waiters)
      (harness-resolve (plist-get waiter :promise) (harness-slots--ticket pool)))))

(provide 'harness-slots)
;;; harness-slots.el ends here
