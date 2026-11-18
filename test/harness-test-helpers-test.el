;;; harness-test-helpers-test.el --- The waits a full run can meet  -*- lexical-binding: t; -*-

;;; Commentary:

;; A suite that shares the machine with a full run must not fail because
;; the machine got busier after the suite started.  The bound a wait uses
;; is asked for again as the wait runs (`harness-test--scale'), so the
;; load a later suite adds lengthens a bound already being spent.

;;; Code:

(require 'harness-test-helpers)

(defun harness-test-helpers-test--with-load (loads fn)
  "Call FN with `load-average' answering LOADS in turn, the last one repeating.
LOADS are numbers of runnable processes, as `load-average' gives them
in hundredths.  `harness-test-wait-jobs' is two, so a load of 16 on 16
CPUs is one suite's worth and a load of 48 is three."
  (let ((loads loads))
    (cl-letf (((symbol-function 'load-average)
               (lambda (&optional _use-float)
                 (let ((next (if (cdr loads) (pop loads) (car loads))))
                   (list (* 100.0 next) (* 100.0 next) (* 100.0 next)))))
              ((symbol-function 'num-processors) (lambda () 16))
              (harness-test-wait-jobs 2))
      (funcall fn))))

(ert-deftest harness-test-helpers-a-wait-lengthens-as-the-machine-gets-busier ()
  "A bound spent while the machine fills up is not the bound it started with.
The suite that began at load 16 with two suites in the run may wait four
times its idle bound once the rest of the run is up: two suites, at three
CPUs' worth of load each.  A bound fixed when the suite started would
have given up at twice its idle bound, which is where a full run's
load-sensitive suites timed out."
  (harness-test-helpers-test--with-load '(16 48)
    (lambda ()
      (should (= 2 (harness-test--scale)))
      ;; The machine gets busier while the same wait is running.
      (should (= 6 (harness-test--scale)))
      (should (= 6 (harness-test--scale))))))

(ert-deftest harness-test-helpers-a-wait-still-ends-when-the-condition-never-comes ()
  "A wait whose condition never holds still times out, and says the bound it had.
Tracking the load must not turn a stuck wait into an endless one: the
error names the seconds it waited, which is the scaled bound."
  (harness-test-helpers-test--with-load '(16)
    (lambda ()
      (let ((message (condition-case err
                         (progn (harness-test-wait (lambda () nil) 0.05 "nothing")
                                "the wait returned")
                       (error (error-message-string err)))))
        (should (string-match-p "Timed out after .*s waiting for nothing" message))))))

(ert-deftest harness-test-helpers-an-await-still-ends-when-the-promise-never-settles ()
  "An await of a promise that never settles still times out, saying so."
  (harness-test-helpers-test--with-load '(16)
    (lambda ()
      (let ((message (condition-case err
                         (progn (harness-test-await (harness-make-promise) 0.05)
                                "the await returned")
                       (error (error-message-string err)))))
        (should (string-match-p "timed out after .*s waiting for the promise" message))))))

(provide 'harness-test-helpers-test)
;;; harness-test-helpers-test.el ends here
