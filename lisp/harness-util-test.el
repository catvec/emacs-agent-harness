;;; harness-util-test.el --- Asynchronous process writer tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Isolated real pipes, never a user's processes.  Socket/RPC isolation is
;; exercised in harness-acp-tcp-test.el; synchronous send tests are in core.

;;; Code:

(require 'harness-test-helpers)

(defun harness-util-test-writer-gone (proc state)
  "Await cleanup of PROC's writer STATE, including its thread and timer."
  (harness-test-wait (lambda () (and (not (process-get proc 'harness--async-send))
                                    (not (thread-live-p (harness--async-send-thread state)))))
                     3 "writer shutdown")
  (should-not (harness--async-send-timer state))
  (should-not (harness--async-send-queue state))
  (should-not (harness--async-send-active state))
  (should (= 0 (harness--async-send-bytes state))))

(ert-deftest harness-util-async-send-fifo-eof ()
  "The caller returns before a delayed reader; queued EOF follows every byte."
  (let* ((file (make-temp-file "harness-async-send-"))
         (proc (make-process :name "async-delayed-reader" :noquery t :connection-type 'pipe
                            :coding 'utf-8-unix
                            :command (list "sh" "-c" (format "sleep 0.2; cat > %s"
                                                             (shell-quote-argument file)))))
         (big (make-string 300000 ?a))
         (owner (current-thread))
         (start (float-time))
         state timer-thread)
    (unwind-protect
        (progn
          (harness-process-send-async proc big)
          (should (< (- (float-time) start) 0.15))
          (setq state (process-get proc 'harness--async-send))
          (should (eq owner (process-thread proc)))
          (dotimes (i 5) (harness-process-send-async proc (format "<%d>é" i)))
          (let ((tail (copy-sequence "tail")))
            (harness-process-send-async proc tail)
            (aset tail 0 ?X))
          (harness-process-send-eof proc)
          (should-error (harness-process-send-async proc "after EOF"))
          (run-at-time 0.05 nil (lambda () (setq timer-thread (current-thread))))
          (harness-test-wait (lambda () (not (process-live-p proc))) 3 "EOF")
          (harness-util-test-writer-gone proc state)
          (should (eq owner timer-thread))
          (should (equal (concat big "<0>é<1>é<2>é<3>é<4>étail")
                         (with-temp-buffer (insert-file-contents file) (buffer-string)))))
      (harness-process-send-cancel proc)
      (when (process-live-p proc) (delete-process proc))
      (delete-file file))))

(ert-deftest harness-util-async-send-deadline-without-another-send ()
  "A single blocked write expires, even when no later send or EOF occurs."
  (let* ((proc (make-process :name "async-non-reader" :noquery t :connection-type 'pipe
                            :command '("sleep" "20")))
         (start (float-time))
         state)
    (unwind-protect
        (progn
          (harness-process-send-async proc (make-string 300000 ?a) 0.3)
          (setq state (process-get proc 'harness--async-send))
          (harness-test-wait (lambda () (harness--async-send-active state)) 1 "blocked write")
          (should (process-live-p proc))
          (should (harness-process-sending-p proc))
          (harness-test-wait (lambda () (not (process-live-p proc))) 2 "independent deadline")
          (should (< (- (float-time) start) 1.5))
          (harness-util-test-writer-gone proc state))
      (harness-process-send-cancel proc)
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest harness-util-async-send-byte-bound-includes-in-flight ()
  "The active string remains charged while blocked in the kernel."
  (let* ((proc (make-process :name "async-byte-bound" :noquery t :connection-type 'pipe
                            :coding 'utf-8-unix :command '("sleep" "20")))
         (harness-process-send-max-bytes 300001)
         state)
    (unwind-protect
        (progn
          (harness-process-send-async proc (make-string 300000 ?a))
          (setq state (process-get proc 'harness--async-send))
          (harness-test-wait (lambda () (harness--async-send-active state)) 1 "blocked write")
          (should (= 300000 (harness--async-send-bytes state)))
          ;; One character, but two UTF-8 bytes: exact wire-byte accounting.
          (should-error (harness-process-send-async proc "é"))
          (should-not (process-live-p proc))
          (harness-util-test-writer-gone proc state))
      (harness-process-send-cancel proc)
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest harness-util-async-send-message-bound ()
  "Empty messages cannot grow a zero-byte unbounded queue."
  (let* ((proc (make-process :name "async-message-bound" :noquery t :connection-type 'pipe
                            :command '("sleep" "20")))
         (harness-process-send-max-messages 2))
    (unwind-protect
        ;; Hold the first write active; empty messages queue behind it.
        (progn
          (harness-process-send-async proc (make-string 300000 ?a))
          (harness-process-send-async proc "")
          (should-error (harness-process-send-async proc ""))
          (should-not (process-live-p proc))
          (should-not (process-get proc 'harness--async-send)))
      (harness-process-send-cancel proc)
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest harness-util-async-send-idle-cancel ()
  "Closing an idle writer wakes its condition wait, leaving no orphan."
  (let* ((proc (make-process :name "async-idle-reader" :noquery t :connection-type 'pipe
                            :command '("cat") :filter #'ignore))
         state)
    (unwind-protect
        (progn
          (harness-process-send-async proc "hello")
          (setq state (process-get proc 'harness--async-send))
          (harness-test-wait (lambda () (not (harness-process-sending-p proc))) 2 "drained write")
          (should (thread-live-p (harness--async-send-thread state)))
          (harness-process-send-cancel proc)
          (delete-process proc)
          (harness-util-test-writer-gone proc state)
          (harness-process-send-cancel proc))
      (harness-process-send-cancel proc)
      (when (process-live-p proc) (delete-process proc)))))

(provide 'harness-util-test)
;;; harness-util-test.el ends here
