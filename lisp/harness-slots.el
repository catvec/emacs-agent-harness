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
;; A pool is plain state in the process that makes it, with no timer and
;; no module of its own; the library defines no macros, so a change to
;; it does not recompile the modules (`harness--library-files').

;;; Code:

(require 'cl-lib)
(require 'harness-core)

(cl-defstruct (harness-slots--pool (:constructor harness-slots--make-pool)
                                   (:copier nil))
  limit                  ; an integer, or a function of no arguments returning one
  rank                   ; nil, or a function of a waiter's DATA returning a number
  (running 0)            ; how many hold a slot
  waiters)               ; plists (:data DATA :promise PROMISE), oldest first

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
not the order they will be served in when the pool has a rank."
  (mapcar (lambda (waiter) (plist-get waiter :data))
          (harness-slots--pool-waiters pool)))

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

(defun harness-slots--ticket (pool)
  "Return the function that gives one slot of POOL back, once."
  (let ((given nil))
    (lambda ()
      (unless given
        (setq given t)
        (harness-slots--give pool)))))

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
      (cl-incf (harness-slots--pool-running pool))
      (harness-resolve (plist-get waiter :promise) (harness-slots--ticket pool)))))

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
      (progn
        (cl-incf (harness-slots--pool-running pool))
        (harness-resolved (harness-slots--ticket pool)))
    (let ((promise (harness-make-promise)))
      (setf (harness-slots--pool-waiters pool)
            (nconc (harness-slots--pool-waiters pool)
                   (list (list :data data :promise promise))))
      promise)))

(defun harness-slots-flush (pool)
  "Let every waiter of POOL run now, and count no one as holding a slot.
What a pool does when its work is given up: nobody waits any longer, the
waiters are started oldest first, and the count of slots held goes back
to 0, so the waiters hold tickets of slots that are not counted.  The
tickets handed out before still work; giving a slot back never takes
the count below 0."
  (let ((waiters (harness-slots--pool-waiters pool)))
    (setf (harness-slots--pool-waiters pool) nil
          (harness-slots--pool-running pool) 0)
    (dolist (waiter waiters)
      (harness-resolve (plist-get waiter :promise) (harness-slots--ticket pool)))))

(provide 'harness-slots)
;;; harness-slots.el ends here
