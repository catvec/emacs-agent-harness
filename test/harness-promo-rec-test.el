;;; harness-promo-rec-test.el --- Tests for the promo film's recorder  -*- lexical-binding: t; -*-

;;; Commentary:

;; promo/capture/promo-rec.el records the harness as the footage of the promo
;; film: a virtual clock of 30 frames a second, a person's typing, things
;; waited for.  The footage is only worth anything if it is the same on a slow
;; machine and a fast one, and the same on every run, so what makes it so is
;; tested here, without a display: the clock the harness reads, the rhythm of
;; typing, and what the recorder does when a thing it waits for never happens.
;; The frames themselves (`x-export-frames') need a display and are not
;; exercised: `promo-rec--grab' is replaced by a counter.

;;; Code:

(require 'harness-test-helpers)

(load (expand-file-name "promo/capture/promo-rec.el" harness-test-root) nil 'nomessage)

(defvar promo-rec-out)
(defvar promo-rec--plan)
(defvar promo-rec--seed)
(defvar promo-rec--done)
(defvar promo-rec--clock-frozen)
(defvar promo-rec--seg)
(defvar promo-rec--watchers)
(defvar promo-rec--queue)
(declare-function promo-rec-begin "promo-rec")
(declare-function promo-rec-end "promo-rec")
(declare-function promo-rec-play "promo-rec")
(declare-function promo-rec-type-at "promo-rec")
(declare-function promo-rec-when-at "promo-rec")
(declare-function promo-rec-frame "promo-rec")
(declare-function promo-rec--clock-install "promo-rec")
(declare-function promo-rec--clock-freeze "promo-rec")
(declare-function promo-rec--clock-thaw "promo-rec")
(declare-function promo-rec--tick "promo-rec")

(defmacro harness-promo-rec-test--with-recorder (&rest body)
  "Run BODY with a recorder that writes into a temporary directory.
No picture is taken: a frame is a count.  The segments, the seed of the typing
and the clock are as they are when a recording starts."
  (declare (indent 0))
  `(let* ((promo-rec-out (file-name-as-directory (make-temp-file "promo-rec-test-" t)))
          (promo-rec--seg nil)
          (promo-rec--done nil)
          (promo-rec--queue nil)
          (promo-rec--watchers nil)
          (promo-rec--seed 12345))
     (unwind-protect
         (cl-letf (((symbol-function 'promo-rec--grab)
                    (lambda ()
                      (cl-incf (promo-rec-seg-frame promo-rec--seg))))
                   ((symbol-function 'promo-rec--settle) #'ignore))
           ,@body)
       (delete-directory promo-rec-out t))))

(defun harness-promo-rec-test--typing-frames (text)
  "The frames at which a segment that types TEXT from frame 10 presses a key."
  (harness-promo-rec-test--with-recorder
    (promo-rec-begin "typing")
    (let* ((end (promo-rec-type-at 10 text :cps 14.0))
           (frames (sort (hash-table-keys promo-rec--plan) #'<)))
      (prog1 (list end frames)
        (clrhash promo-rec--plan)
        (promo-rec-end)))))

(ert-deftest harness-promo-rec-test-typing-is-a-persons-and-is-repeatable ()
  "The same text is typed in the same rhythm every time, one key a character."
  (let* ((text "show me what Emacs agent harness can do")
         (first (harness-promo-rec-test--typing-frames text))
         (second (harness-promo-rec-test--typing-frames text)))
    (should (equal first second))
    (pcase-let ((`(,end ,frames) first))
      ;; Every character is typed, in order, not all on one frame.
      (should (<= (length frames) (length text)))
      (should (> (length frames) (/ (length text) 2)))
      (should (equal frames (sort (copy-sequence frames) #'<)))
      (should (= (car frames) 10))
      ;; At about 14 characters a second, 39 characters take about 84 frames.
      (should (< 60 (- end 10) 130))
      (should (> end (car (last frames)))))))

(ert-deftest harness-promo-rec-test-a-different-text-is-a-different-rhythm ()
  "The rhythm follows the text: spaces take longer than letters."
  (let ((words (harness-promo-rec-test--typing-frames "a b c d e f g h i j"))
        (letters (harness-promo-rec-test--typing-frames "abcdefghijklmnopqrs")))
    (should (> (car words) (car letters)))))

(ert-deftest harness-promo-rec-test-the-clock-stands-still-between-frames ()
  "The harness reads a clock that a frame moves by 1/30 s, and no more."
  (let ((promo-rec--clock-frozen nil))
    (unwind-protect
        (progn
          (promo-rec--clock-install)
          ;; Off camera it follows the real clock.
          (should (< (abs (- (float-time) (promo-rec-real-time))) 0.5))
          (promo-rec--clock-freeze)
          (let ((a (float-time)) (b (float-time)))
            ;; Strictly increasing, so a rate is never a division by zero, but by nothing that shows.
            (should (> b a))
            (should (< (- b a) 1e-4))
            (harness-promo-rec-test--with-recorder
              (setq promo-rec--clock-frozen t)
              (promo-rec--tick)
              (let ((after (float-time)))
                (should (< (abs (- after a (/ 1.0 promo-rec-fps))) 1e-3)))))
          ;; A time asked for is not touched.
          (should (= (float-time '(0 100)) 100.0))
          (promo-rec--clock-thaw)
          (should (< (abs (- (float-time) (promo-rec-real-time))) 0.5)))
      (advice-remove 'float-time #'promo-rec--float-time))))

(ert-deftest harness-promo-rec-test-what-is-waited-for-is-met-once ()
  "A thing that happens at its own pace is waited for, and met once, where it is."
  (harness-promo-rec-test--with-recorder
    (promo-rec-begin "waiting")
    (let ((met nil))
      (promo-rec-when-at 2 (lambda () (>= (promo-rec-frame) 5))
                         (lambda () (push (promo-rec-frame) met))
                         "frame five")
      (promo-rec-play 10)
      (should (equal met '(5)))
      (promo-rec-end))))

(ert-deftest harness-promo-rec-test-what-never-happens-fails-the-segment ()
  "A segment cannot end while it still waits for something: the footage would be wrong."
  (harness-promo-rec-test--with-recorder
    (promo-rec-begin "never")
    (promo-rec-when-at 0 #'ignore #'ignore "the second task to be reviewed")
    (promo-rec-play 3)
    (let ((err (should-error (promo-rec-end))))
      (should (string-match-p "the second task to be reviewed" (cadr err))))))

(provide 'harness-promo-rec-test)
;;; harness-promo-rec-test.el ends here
