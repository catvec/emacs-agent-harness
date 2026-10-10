;;; harness-slots-test.el --- Tests for the pools of slots  -*- lexical-binding: t; -*-

;;; Commentary:

;; The library (lisp/harness-slots.el) holds work to so many at once and
;; makes the rest wait.  The tests drive a pool by hand: they ask for
;; slots, give them back with the tickets, and watch which askers are
;; served and in what order.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-slots)

;;;; Helpers

(defvar harness-slots-test--served nil
  "The DATA of the askers that were served a slot, newest first.")

(defun harness-slots-test--ask (pool data)
  "Ask POOL for a slot with DATA, noting when it is served; return the promise."
  (let ((promise (harness-slots-acquire pool data)))
    (harness-then promise (lambda (_ticket) (push data harness-slots-test--served) nil))
    promise))

(defun harness-slots-test--order ()
  "Return the DATA of the askers served so far, oldest first."
  (reverse harness-slots-test--served))

(defun harness-slots-test--ticket (promise)
  "Return the ticket PROMISE was resolved with, nil while it still waits."
  (and (harness-promise-settled-p promise)
       (harness-promise-value promise)))

(defun harness-slots-test--give (promise)
  "Give back the slot that PROMISE was resolved with a ticket for."
  (funcall (or (harness-slots-test--ticket promise) (error "No slot was granted"))))

;;;; Giving slots out

(ert-deftest harness-slots-grants-a-slot-at-once-while-there-is-room ()
  "An asker is served at once, with a ticket, while the pool has room."
  (let* ((pool (harness-slots-create :limit 2))
         (one (harness-slots-acquire pool))
         (two (harness-slots-acquire pool)))
    (should (functionp (harness-slots-test--ticket one)))
    (should (functionp (harness-slots-test--ticket two)))
    (should (= 2 (harness-slots-limit pool)))
    (should (= 2 (harness-slots-running pool)))
    (should (= 0 (harness-slots-waiting pool)))
    (should-not (harness-slots-waiters pool))))

(ert-deftest harness-slots-makes-an-asker-over-the-limit-wait ()
  "An asker over the limit waits until a slot is given back, then has it."
  (let* ((pool (harness-slots-create :limit 1))
         (first (harness-slots-acquire pool 'first))
         (second (harness-slots-acquire pool 'second)))
    (should (harness-slots-test--ticket first))
    (should-not (harness-promise-settled-p second))
    (should (= 1 (harness-slots-running pool)))
    (should (= 1 (harness-slots-waiting pool)))
    (should (equal '(second) (harness-slots-waiters pool)))
    ;; The slot goes back and the waiter has it: still one running.
    (harness-slots-test--give first)
    (should (functionp (harness-slots-test--ticket second)))
    (should (= 1 (harness-slots-running pool)))
    (should (= 0 (harness-slots-waiting pool)))
    (should-not (harness-slots-waiters pool))
    ;; And when it is given back too, the pool is idle.
    (harness-slots-test--give second)
    (should (= 0 (harness-slots-running pool)))))

(ert-deftest harness-slots-serves-the-oldest-first-without-a-rank ()
  "Without a rank the waiters are served in the order they asked."
  (let ((harness-slots-test--served nil)
        (pool (harness-slots-create :limit 1)))
    (let ((hold (harness-slots-test--ask pool 'hold))
          (a (harness-slots-test--ask pool 'a))
          (b (harness-slots-test--ask pool 'b))
          (c (harness-slots-test--ask pool 'c)))
      (should (equal '(hold) (harness-slots-test--order)))
      (should (equal '(a b c) (harness-slots-waiters pool)))
      (harness-slots-test--give hold)
      (should (equal '(hold a) (harness-slots-test--order)))
      (harness-slots-test--give a)
      (should (equal '(hold a b) (harness-slots-test--order)))
      (harness-slots-test--give b)
      (should (equal '(hold a b c) (harness-slots-test--order)))
      (harness-slots-test--give c)
      (should (= 0 (harness-slots-running pool))))))

(ert-deftest harness-slots-serves-by-rank-and-the-oldest-first-among-equals ()
  "With a rank the highest goes first, and askers of one rank keep their order.
The rank is a function of the DATA an asker came with."
  (let* ((harness-slots-test--served nil)
         ;; DATA is (NAME . RANK).
         (pool (harness-slots-create :limit 1 :rank #'cdr))
         (hold (harness-slots-test--ask pool '(hold . 0)))
         (low-old (harness-slots-test--ask pool '(low-old . 1)))
         (high-old (harness-slots-test--ask pool '(high-old . 5)))
         (low-new (harness-slots-test--ask pool '(low-new . 1)))
         (high-new (harness-slots-test--ask pool '(high-new . 5))))
    (ignore low-new)
    ;; The line is listed as it came, not as it will be served.
    (should (equal '(low-old high-old low-new high-new)
                   (mapcar #'car (harness-slots-waiters pool))))
    (harness-slots-test--give hold)
    (harness-slots-test--give high-old)
    (harness-slots-test--give high-new)
    (harness-slots-test--give low-old)
    (should (equal '(hold high-old high-new low-old low-new)
                   (mapcar #'car (harness-slots-test--order))))))

(ert-deftest harness-slots-reads-a-rank-again-when-a-slot-frees ()
  "A waiter whose rank rose while it waited goes before an older one.
Ranks are read whenever a slot frees, not once when a waiter asks or
the first time anyone looks."
  (let* ((harness-slots-test--served nil)
         (ranks (list (cons 'hold 0) (cons 'first 1) (cons 'second 1) (cons 'third 1)))
         (pool (harness-slots-create :limit 1
                                     :rank (lambda (data) (cdr (assq data ranks)))))
         (hold (harness-slots-test--ask pool 'hold))
         (first (harness-slots-test--ask pool 'first))
         (second (harness-slots-test--ask pool 'second))
         (third (harness-slots-test--ask pool 'third)))
    (ignore first)
    (should (equal '(hold) (harness-slots-test--order)))
    ;; The newest one's rank rises while all three wait.
    (setcdr (assq 'third ranks) 9)
    (harness-slots-test--give hold)
    (should (equal '(hold third) (harness-slots-test--order)))
    ;; The ranks were read at that slot already; the next one reads them again.
    (setcdr (assq 'second ranks) 5)
    (harness-slots-test--give third)
    (should (equal '(hold third second) (harness-slots-test--order)))
    (harness-slots-test--give second)
    (should (equal '(hold third second first) (harness-slots-test--order)))))

(ert-deftest harness-slots-counts-a-rank-that-is-no-number-as-0 ()
  "A rank function that says nothing useful ranks the waiter 0."
  (let* ((harness-slots-test--served nil)
         (pool (harness-slots-create :limit 1
                                     :rank (lambda (data) (and (numberp data) data))))
         (hold (harness-slots-test--ask pool 100))
         (plain (harness-slots-test--ask pool 'plain))
         (negative (harness-slots-test--ask pool -1))
         (two (harness-slots-test--ask pool 2)))
    (ignore negative)
    (harness-slots-test--give hold)
    ;; 2 beats the plain one's 0, which beats -1.
    (harness-slots-test--give two)
    (harness-slots-test--give plain)
    (should (equal '(100 2 plain -1) (harness-slots-test--order)))))

(ert-deftest harness-slots-a-ticket-gives-its-slot-back-once ()
  "A ticket called again gives nothing more back."
  (let* ((pool (harness-slots-create :limit 2))
         (one (harness-slots-acquire pool 'one))
         (two (harness-slots-acquire pool 'two))
         (third (harness-slots-acquire pool 'third))
         (fourth (harness-slots-acquire pool 'fourth)))
    (should (= 2 (harness-slots-running pool)))
    (should (equal '(third fourth) (harness-slots-waiters pool)))
    ;; Called three times, it frees one slot, which the oldest waiter takes.
    (let ((ticket (harness-slots-test--ticket one)))
      (funcall ticket)
      (funcall ticket)
      (funcall ticket))
    (should (harness-slots-test--ticket third))
    (should-not (harness-promise-settled-p fourth))
    (should (= 2 (harness-slots-running pool)))
    (should (equal '(fourth) (harness-slots-waiters pool)))
    ;; Each ticket is its own: two's still frees a slot.
    (harness-slots-test--give two)
    (should (harness-slots-test--ticket fourth))
    (should (= 2 (harness-slots-running pool)))))

(ert-deftest harness-slots-asking-starts-those-that-room-opened-for-first ()
  "A waiter the limit has room for, not yet admitted, goes before a new asker."
  (let* ((harness-slots-test--served nil)
         (limit 1)
         (pool (harness-slots-create :limit (lambda () limit))))
    (harness-slots-test--ask pool 'hold)
    (let ((older (harness-slots-test--ask pool 'older)))
      (should-not (harness-promise-settled-p older))
      (setq limit 2)
      ;; Nobody admitted the older one, and a new asker comes.
      (let ((newer (harness-slots-test--ask pool 'newer)))
        (should (harness-slots-test--ticket older))
        (should-not (harness-promise-settled-p newer))
        (should (equal '(hold older) (harness-slots-test--order)))
        (should (equal '(newer) (harness-slots-waiters pool)))))))

(ert-deftest harness-slots-a-waiter-may-hand-its-slot-on-as-it-starts ()
  "A waiter that gives its slot back the moment it starts finds the pool in order.
The pool is brought up to date before a waiter is told it has a slot."
  (let* ((pool (harness-slots-create :limit 1))
         (hold (harness-slots-acquire pool 'hold))
         (done nil))
    (dolist (name '(a b c))
      (harness-then (harness-slots-acquire pool name)
                    (lambda (ticket)
                      (push (list name (harness-slots-running pool)) done)
                      (funcall ticket)
                      nil)))
    (should (equal '(a b c) (harness-slots-waiters pool)))
    (harness-slots-test--give hold)
    ;; Each ran with the one slot counted as taken, and passed it on.
    (should (equal '((a 1) (b 1) (c 1)) (reverse done)))
    (should (= 0 (harness-slots-running pool)))
    (should (= 0 (harness-slots-waiting pool)))))

;;;; The limit

(ert-deftest harness-slots-a-raised-limit-starts-the-waiters-on-admit ()
  "Raising the limit starts nobody; admitting starts those that now fit, by rank."
  (let* ((harness-slots-test--served nil)
         (limit 1)
         (pool (harness-slots-create :limit (lambda () limit) :rank #'cdr)))
    (harness-slots-test--ask pool '(hold . 0))
    (harness-slots-test--ask pool '(a . 1))
    (harness-slots-test--ask pool '(b . 3))
    (harness-slots-test--ask pool '(c . 2))
    (setq limit 3)
    (should (= 3 (harness-slots-limit pool)))
    (should (= 3 (harness-slots-waiting pool)))
    (should (equal '(hold) (mapcar #'car (harness-slots-test--order))))
    (harness-slots-admit pool)
    ;; Two fit, and the ones of the highest rank take them.
    (should (equal '(hold b c) (mapcar #'car (harness-slots-test--order))))
    (should (= 3 (harness-slots-running pool)))
    (should (equal '((a . 1)) (harness-slots-waiters pool)))
    ;; Admitting again with no room left starts nobody.
    (harness-slots-admit pool)
    (should (= 3 (harness-slots-running pool)))
    (should (equal '((a . 1)) (harness-slots-waiters pool)))))

(ert-deftest harness-slots-a-limit-of-0-holds-everyone-until-it-rises ()
  "With a limit of 0 every asker waits, until the limit rises and they are admitted."
  (let* ((limit 0)
         (pool (harness-slots-create :limit (lambda () limit)))
         (one (harness-slots-acquire pool 'one))
         (two (harness-slots-acquire pool 'two)))
    (should-not (harness-promise-settled-p one))
    (should-not (harness-promise-settled-p two))
    (should (= 0 (harness-slots-running pool)))
    (setq limit 1)
    (harness-slots-admit pool)
    (should (harness-slots-test--ticket one))
    (should-not (harness-promise-settled-p two))))

(ert-deftest harness-slots-a-fall-in-the-limit-leaves-the-holders-alone ()
  "When the limit falls no holder is stopped, and nobody starts until under it."
  (let* ((limit 3)
         (pool (harness-slots-create :limit (lambda () limit)))
         (one (harness-slots-acquire pool 'one))
         (two (harness-slots-acquire pool 'two))
         (three (harness-slots-acquire pool 'three)))
    (setq limit 1)
    (let ((late (harness-slots-acquire pool 'late)))
      (should-not (harness-promise-settled-p late))
      (should (= 3 (harness-slots-running pool)))
      ;; Admitting starts nobody either.
      (harness-slots-admit pool)
      (should-not (harness-promise-settled-p late))
      (harness-slots-test--give one)
      (harness-slots-test--give two)
      (should-not (harness-promise-settled-p late))
      (should (= 1 (harness-slots-running pool)))
      ;; Only when the last holder is done is the pool under its limit.
      (harness-slots-test--give three)
      (should (harness-slots-test--ticket late))
      (should (= 1 (harness-slots-running pool))))))

(ert-deftest harness-slots-reads-a-limit-function-whenever-it-matters ()
  "A function limit is called when the limit is read, so it can change."
  (let* ((limit 1)
         (calls 0)
         (pool (harness-slots-create :limit (lambda () (cl-incf calls) limit))))
    (should (= 1 (harness-slots-limit pool)))
    (should (= 1 calls))
    (setq limit 4)
    (should (= 4 (harness-slots-limit pool)))
    (setq limit 1)
    ;; The limit that holds is the one read when someone asks.
    (let ((one (harness-slots-acquire pool))
          (two (harness-slots-acquire pool)))
      (should (harness-slots-test--ticket one))
      (should-not (harness-promise-settled-p two)))
    ;; A number is the limit as it stands.
    (should (= 3 (harness-slots-limit (harness-slots-create :limit 3))))
    (should (= 0 (harness-slots-limit (harness-slots-create :limit 0))))))

(ert-deftest harness-slots-create-checks-what-it-is-given ()
  "A pool needs a limit that is a number or a function, and a rank that is a function."
  (should-error (harness-slots-create) :type 'wrong-type-argument)
  (should-error (harness-slots-create :limit nil) :type 'wrong-type-argument)
  (should-error (harness-slots-create :limit "two") :type 'wrong-type-argument)
  (should-error (harness-slots-create :limit 1 :rank 3) :type 'wrong-type-argument)
  (should (harness-slots-create :limit 1))
  (should (harness-slots-create :limit #'ignore :rank #'identity)))

;;;; Flushing

(ert-deftest harness-slots-flush-lets-every-waiter-run-at-once ()
  "A flush starts every waiter, oldest first, and counts no slot as held."
  (let* ((harness-slots-test--served nil)
         (pool (harness-slots-create :limit 1))
         (hold (harness-slots-test--ask pool 'hold))
         (a (harness-slots-test--ask pool 'a))
         (b (harness-slots-test--ask pool 'b)))
    (should (= 1 (harness-slots-running pool)))
    (should (= 2 (harness-slots-waiting pool)))
    (harness-slots-flush pool)
    (should (equal '(hold a b) (harness-slots-test--order)))
    (should (functionp (harness-slots-test--ticket a)))
    (should (functionp (harness-slots-test--ticket b)))
    (should (= 0 (harness-slots-running pool)))
    (should (= 0 (harness-slots-waiting pool)))
    (should-not (harness-slots-waiters pool))
    ;; The tickets in hand still work, and the count never goes below 0.
    (harness-slots-test--give hold)
    (harness-slots-test--give a)
    (harness-slots-test--give b)
    (should (= 0 (harness-slots-running pool)))
    ;; And the pool goes on as before.
    (let ((one (harness-slots-acquire pool 'one))
          (two (harness-slots-acquire pool 'two)))
      (should (harness-slots-test--ticket one))
      (should-not (harness-promise-settled-p two))
      (should (= 1 (harness-slots-running pool)))
      (should (equal '(two) (harness-slots-waiters pool))))))

(ert-deftest harness-slots-flush-of-an-idle-pool-does-nothing ()
  "Flushing a pool with no waiter starts nobody and changes nothing but the count."
  (let ((pool (harness-slots-create :limit 2)))
    (harness-slots-flush pool)
    (should (= 0 (harness-slots-running pool)))
    (should (= 0 (harness-slots-waiting pool)))
    (should (harness-slots-test--ticket (harness-slots-acquire pool)))))

(provide 'harness-slots-test)
;;; harness-slots-test.el ends here
