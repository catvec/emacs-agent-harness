;;; harness-latency-test.el --- Latency evidence without user content -*- lexical-binding: t; -*-

(require 'harness-test-helpers)
(require 'harness-latency)

(defmacro harness-latency-test--with-recorder (&rest body)
  "Run BODY with a recorder and directory of its own."
  (declare (indent 0))
  `(let ((harness-state-directory (make-temp-file "latency-test-" t))
         (harness-latency-enabled t)
         (harness-latency-threshold 0.005)
         (harness-latency--interval 0.02)
         (harness-latency--installed nil) (harness-latency--timer nil)
         (harness-latency--records nil) (harness-latency--dropped 0)
         (harness-latency--advices nil) (harness-latency--active nil)
         (harness-latency--targets nil) (harness-latency--extra-targets nil)
         (harness-latency--last-tick nil) (harness-latency--redisplay nil)
         (harness-latency--gc-elapsed gc-elapsed)
         (harness-latency--tick-gc gc-elapsed) (harness-latency--tick-gcs gcs-done))
     (unwind-protect (progn ,@body)
       (harness-latency-uninstall)
       (delete-directory harness-state-directory t))))

(defun harness-latency-test--busy (seconds &optional _data)
  "Keep the current thread busy for SECONDS, without yielding."
  (let ((end (+ (float-time) seconds)))
    (while (< (float-time) end)))
  'answer)

(ert-deftest harness-latency-completion-keeps-metadata-not-arguments ()
  (harness-latency-test--with-recorder
    (setq harness-latency--installed t)
    (should (eq 'answer
                (harness-latency-call 'ui-handler 'harness-latency-test--busy
                                      #'harness-latency-test--busy 0.02
                                      "token=should-never-be-recorded")))
    (let ((record (car harness-latency--records)))
      (should (eq 'completed (plist-get record :kind)))
      (should (equal "harness-latency-test--busy" (plist-get record :operation)))
      (should (>= (plist-get record :seconds) 0.02))
      (should (numberp (plist-get record :gc-seconds)))
      (should (<= (length (plist-get record :stack)) 32))
      (should (cl-every #'stringp (plist-get record :stack)))
      (should-not (string-match-p "should-never-be-recorded" (prin1-to-string record))))
    ;; Exceptions/non-local exits and return values survive even a broken recorder.
    (let ((harness-latency-threshold 0))
      (cl-letf (((symbol-function 'harness-latency--stack) (lambda () (error "recorder"))))
        (should (equal '(error "original")
                       (condition-case err
                           (harness-latency-call 'test 'error #'error "original")
                         (error err))))
        (should (eq 'escaped (catch 'escape
                              (harness-latency-call 'test 'throw
                                                    (lambda () (throw 'escape 'escaped))))))))))

(ert-deftest harness-latency-disabled-is-transparent ()
  (harness-latency-test--with-recorder
    (setq harness-latency-enabled nil)
    (harness-latency-install)
    (should-not harness-latency--timer)
    (should (= 42 (harness-latency-call 'test 'identity #'identity 42)))
    (should-not harness-latency--records)))

(ert-deftest harness-latency-watchdog-samples-a-yielding-handler ()
  (harness-latency-test--with-recorder
    (harness-latency-install)
    (let ((timer harness-latency--timer))
      (harness-latency-install)
      (should (eq timer harness-latency--timer)))
    (harness-latency-call 'rpc-handler 'sleep-for #'sleep-for 0.1)
    (harness-latency-flush)
    (let ((text (harness-read-file (harness-latency-file))))
      (should (string-match-p ":kind sample" text))
      (should (string-match-p ":kind completed" text))
      (should (string-match-p "sleep-for" text)))
    (harness-latency-uninstall)
    (should-not harness-latency--timer)
    (should-not (memq #'harness-latency--after-gc post-gc-hook))))

(ert-deftest harness-latency-queue-rotation-and-failures-are-bounded ()
  (harness-latency-test--with-recorder
    (let ((harness-latency--capacity 4)
          (harness-latency--max-bytes 1))
      (dotimes (i 10) (harness-latency--record (list :kind 'test :n i)))
      (should (= 4 (length harness-latency--records)))
      (should (= 6 harness-latency--dropped))
      (harness-latency-flush)
      (should-not harness-latency--records)
      (let ((text (harness-read-file (harness-latency-file))))
        (should (string-match-p ":kind dropped :count 6" text))
        (should (string-match-p ":n 9" text))
        (should-not (string-match-p ":n 0" text)))
      (harness-latency--record '(:kind second))
      (harness-latency-flush)
      (should (file-exists-p (concat (harness-latency-file) ".1")))
      (should (= #o600 (file-modes (harness-latency-file))))
      ;; Failed I/O does not recurse via harness-log and keeps a bounded retry.
      (harness-latency--record '(:kind failed-write))
      (cl-letf (((symbol-function 'write-region) (lambda (&rest _) (error "disk")))
                ((symbol-function 'harness-log) (lambda (&rest _) (ert-fail "recursive log"))))
        (harness-latency-flush))
      (should (= 1 (length harness-latency--records))))))

(ert-deftest harness-latency-gaps-gc-and-redisplay-are-distinct ()
  (harness-latency-test--with-recorder
    (let ((harness-latency--last-tick (- (float-time) 10))
          (harness-latency--tick-gc (- gc-elapsed 0.5))
          (harness-latency--tick-gcs (- gcs-done 5)))
      (harness-latency--before-redisplay)
      (cl-letf (((symbol-function 'harness-latency-flush) #'ignore))
        (harness-latency--tick))
      (let ((gap (cl-find 'loop-gap harness-latency--records
                          :key (lambda (r) (plist-get r :kind)))))
        (should (>= (plist-get gap :seconds) 10))
        (should (= 5 (plist-get gap :gcs)))
        (should (= 0.5 (plist-get gap :gc-seconds)))
        (should (numberp (plist-get gap :since-redisplay))))
      (should (cl-find 'gc-window harness-latency--records
                       :key (lambda (r) (plist-get r :kind)))))
    (let ((harness-latency--gc-elapsed (- gc-elapsed 0.5)))
      (harness-latency--after-gc)
      (should (eq 'gc (plist-get (car harness-latency--records) :kind))))
    ;; No remote file handler or network probe in the evidence path.
    (let ((harness-state-directory "/ssh:absent:/tmp/"))
      (should-not (harness-latency-file)))))

(ert-deftest harness-latency-optional-modules-register-their-own-boundaries ()
  (harness-latency-test--with-recorder
    (let ((symbol (make-symbol "latency-test-target")))
      (harness-latency-install)
      (harness-latency-register-target symbol 'render)
      (harness-latency-register-target symbol 'render)
      (should (= 1 (length harness-latency--extra-targets)))
      (should-not (alist-get symbol harness-latency--advices))
      (fset symbol (lambda () (harness-latency-test--busy 0.02)))
      (harness-latency--sync)
      (funcall symbol)
      (should (eq 'render (plist-get (car harness-latency--records) :category)))
      (should (equal "latency-test-target" (plist-get (car harness-latency--records) :operation))))))

(ert-deftest harness-latency-advice-installation-is-not-reentrant ()
  "Installing advice may load another library and run after-load-functions."
  (harness-latency-test--with-recorder
    (let ((harness-latency--targets '((harness-latency-test--busy . render)))
          (add (symbol-function 'advice-add)) (calls 0))
      (cl-letf (((symbol-function 'advice-add)
                 (lambda (&rest args)
                   (cl-incf calls)
                   (harness-latency--sync)
                   (apply add args))))
        (harness-latency-install))
      (should (= 1 calls)))))

(ert-deftest harness-latency-leaves-the-redisplay-primitive-intact ()
  "Timing must not replace the display primitive or require a native trampoline."
  (let ((targets harness-latency--targets))
    (harness-latency-test--with-recorder
      (let ((harness-latency--targets targets))
        (harness-latency-install)
        (should (subrp (symbol-function 'redisplay)))
        (should-not (assq 'redisplay harness-latency--targets))
        (let ((harness-latency-threshold 0))
          (harness-latency-redisplay t)
          (should (equal "redisplay" (plist-get (car harness-latency--records) :operation))))))))

(ert-deftest harness-latency-advice-is-late-loaded-and-removable ()
  (harness-latency-test--with-recorder
    (let ((harness-latency--targets '((harness-latency-test--busy . render))))
      (harness-latency-install)
      (harness-latency--sync)
      (harness-latency-test--busy 0.02)
      (should (= 1 (length harness-latency--records)))
      (let ((advice (alist-get 'harness-latency-test--busy harness-latency--advices)))
        (should (advice-member-p advice 'harness-latency-test--busy))
        (harness-latency-uninstall)
        (should-not (advice-member-p advice 'harness-latency-test--busy))))))

(provide 'harness-latency-test)
;;; harness-latency-test.el ends here
