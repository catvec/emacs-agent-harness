;;; harness-provider-process-test.el --- Tests for the process transport -*- lexical-binding: t; -*-

;; Copyright (C) 2026 the emacs-agent-harness authors

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The process transport is exercised against small shell scripts written to
;; temp files by the tests and invoked via `sh'.  `harness-test-wait-for'
;; (from `harness-test-util') pumps the event loop, which is allowed here.

;;; Code:

(require 'ert)
(require 'harness-provider-process)
(require 'harness-test-util)

(defun harness-provider-process-test--run (body &optional on-message)
  "Write BODY (a shell script body) to a temp file and run it in a transport.
Returns (TRANSPORT SEEN FILE).  SEEN is a plist the transport's callbacks
update: `:messages' is the list of parsed stdout messages, `:stderr' the
accumulated stderr text, `:exit' a (STATUS DESCRIPTION) list on exit."
  (let* ((file (make-temp-file "harness-process-" nil ".sh"))
         (seen (list :messages nil :stderr "" :exit nil)))
    (write-region (concat "#!/bin/sh\n" body "\n") nil file)
    (let ((transport
           (harness-provider-process-transport-create
            (list :name 'test
                  :command "sh"
                  :args (list file)
                  :on-message (lambda (message)
                                (setq seen
                                      (plist-put seen :messages
                                                 (append (plist-get seen :messages)
                                                         (list message))))
                                (when on-message (funcall on-message message)))
                  :on-stderr (lambda (text)
                               (setq seen
                                     (plist-put seen :stderr
                                                (concat (plist-get seen :stderr)
                                                        text))))
                  :on-exit (lambda (status description)
                             (setq seen (plist-put seen :exit
                                                   (list status description))))))))
      (list transport seen file))))

(ert-deftest harness-provider-process-test-request-reply ()
  "A JSON-RPC request gets its parsed result back through the callback."
  (let* ((run (harness-provider-process-test--run
               "read line
printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}'"))
         (transport (nth 0 run))
         (file (nth 2 run))
         result)
    (unwind-protect
        (progn
          (harness-provider-process-transport-request
           transport "echo" '((x . 1))
           (lambda (error res) (setq result (list error res))))
          (should (harness-test-wait-for (lambda () result) 5))
          (should-not (car result))
          (should (equal (harness-alist-get :ok (cadr result)) t)))
      (harness-provider-process-transport-stop transport)
      (delete-file file))))

(ert-deftest harness-provider-process-test-id-correlation ()
  "Two interleaved requests correlate by id, not by arrival order."
  (let* ((run (harness-provider-process-test--run
               "read line1
read line2
printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":\"second\"}'
printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"first\"}'"))
         (transport (nth 0 run))
         (file (nth 2 run))
         results)
    (unwind-protect
        (progn
          (harness-provider-process-transport-request
           transport "first-method" '()
           (lambda (error res) (push (list "first" error res) results)))
          (harness-provider-process-transport-request
           transport "second-method" '()
           (lambda (error res) (push (list "second" error res) results)))
          (should (harness-test-wait-for (lambda () (>= (length results) 2)) 5))
          (should-not (cadr (assoc "first" results)))
          (should-not (cadr (assoc "second" results)))
          (should (equal (caddr (assoc "first" results)) "first"))
          (should (equal (caddr (assoc "second" results)) "second")))
      (harness-provider-process-transport-stop transport)
      (delete-file file))))

(ert-deftest harness-provider-process-test-feed-reassembly ()
  "Lines split across feed calls are reassembled before parsing."
  (let* ((seen nil)
         (transport
          (harness-provider-process-transport-create
           (list :name 't :command "sh" :args nil
                 :on-message (lambda (m) (push m seen))
                 :on-stderr #'ignore))))
    (harness-provider-process--feed transport "{\"kind\":\"partial\",\"va")
    (should-not seen)
    (harness-provider-process--feed transport "lue\":\"done\"}\n")
    (should (equal (length seen) 1))
    (should (equal (harness-alist-get :kind (car seen)) "partial"))
    (should (equal (harness-alist-get :value (car seen)) "done"))))

(ert-deftest harness-provider-process-test-child-reassembly ()
  "A JSON line written by the child in two writes is reassembled.
The awk `fflush' forces the first half onto the pipe before the sleep, so the
transport sees two separate chunks."
  (let* ((run (harness-provider-process-test--run
               "awk 'BEGIN { printf \"%s\", \"{\\\"kind\\\":\\\"partial\\\",\\\"value\\\":\\\"\"; fflush() }'
sleep 0.05
awk 'BEGIN { printf \"%s\\n\", \"done\\\"}\" }'"))
         (transport (nth 0 run))
         (seen (nth 1 run))
         (file (nth 2 run)))
    (unwind-protect
        (progn
          (harness-provider-process-transport-start transport)
          (should (harness-test-wait-for (lambda () (plist-get seen :messages)) 5))
          (let ((message (car (plist-get seen :messages))))
            (should (equal (harness-alist-get :kind message) "partial"))
            (should (equal (harness-alist-get :value message) "done"))))
      (harness-provider-process-transport-stop transport)
      (delete-file file))))

(ert-deftest harness-provider-process-test-stderr-separate ()
  "Stderr is captured separately and does not disturb stdout framing."
  (let* ((run (harness-provider-process-test--run
               "printf '%s' '{\"result\":\"'
printf '%s\\n' 'oops' >&2
printf '%s\\n' 'ok\"}'"))
         (transport (nth 0 run))
         (seen (nth 1 run))
         (file (nth 2 run)))
    (unwind-protect
        (progn
          (harness-provider-process-transport-start transport)
          (should (harness-test-wait-for (lambda () (plist-get seen :messages)) 5))
          (let ((message (car (plist-get seen :messages))))
            (should (equal (harness-alist-get :result message) "ok")))
          (should (string-match-p "oops" (plist-get seen :stderr))))
      (harness-provider-process-transport-stop transport)
      (delete-file file))))

(ert-deftest harness-provider-process-test-malformed-line ()
  "A malformed line is reported to stderr; the next line is still delivered."
  (let* ((run (harness-provider-process-test--run
               "printf '%s\\n' 'this is not json'
printf '%s\\n' '{\"result\":\"ok\"}'"))
         (transport (nth 0 run))
         (seen (nth 1 run))
         (file (nth 2 run)))
    (unwind-protect
        (progn
          (harness-provider-process-transport-start transport)
          (should (harness-test-wait-for (lambda () (plist-get seen :messages)) 5))
          (should (equal (harness-alist-get :result (car (plist-get seen :messages)))
                         "ok"))
          (should (string-match-p "unparseable" (plist-get seen :stderr))))
      (harness-provider-process-transport-stop transport)
      (delete-file file))))

(ert-deftest harness-provider-process-test-stop-fails-pending ()
  "Stopping the transport fails pending callbacks with a clear error."
  (let* ((run (harness-provider-process-test--run
               "read line
sleep 100"))
         (transport (nth 0 run))
         (file (nth 2 run))
         reply)
    (unwind-protect
        (progn
          (harness-provider-process-transport-send
           transport '((id . 1) (method . "ping"))
           (lambda (message) (setq reply message)))
          (harness-provider-process-transport-stop transport)
          (should reply)
          (should (string-match-p "stopped" (harness-plist-or-alist-get :error reply)))
          (should-not (harness-provider-process-transport-live-p transport)))
      (harness-provider-process-transport-stop transport)
      (delete-file file))))

(ert-deftest harness-provider-process-test-send-after-stop-restarts ()
  "Sending after a stop starts a fresh subprocess."
  (let* ((run (harness-provider-process-test--run
               "read line
printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"pong\"}'"))
         (transport (nth 0 run))
         (file (nth 2 run))
         first second)
    (unwind-protect
        (progn
          (harness-provider-process-transport-send
           transport '((id . 1) (method . "ping"))
           (lambda (message) (setq first message)))
          (should (harness-test-wait-for (lambda () first) 5))
          (should (equal (harness-alist-get :result first) "pong"))
          (harness-provider-process-transport-stop transport)
          (should-not (harness-provider-process-transport-live-p transport))
          ;; The next send lazily restarts the process.
          (harness-provider-process-transport-send
           transport '((id . 1) (method . "ping"))
           (lambda (message) (setq second message)))
          (should (harness-test-wait-for (lambda () second) 5))
          (should (equal (harness-alist-get :result second) "pong"))
          (should (equal (harness-provider-process-transport-restart-count transport) 1)))
      (harness-provider-process-transport-stop transport)
      (delete-file file))))

(provide 'harness-provider-process-test)
;;; harness-provider-process-test.el ends here
