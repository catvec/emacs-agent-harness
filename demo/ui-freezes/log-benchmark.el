;;; log-benchmark.el --- Full log burst benchmark -*- lexical-binding: t; -*-

;; A fresh batch Emacs only.  The caller chooses a before/after compiled core.
(require 'harness-core)
(require 'benchmark)
(let ((harness-log-hook nil) (harness-log-filter-function nil)
      (harness-log-level 'info) (payload (make-string 1000 ?x))
      (gc-cons-threshold (* 16 1024 1024))
      (entries (string-to-number (or (getenv "HARNESS_FREEZE_LOG_ENTRIES") "80000"))))
  (with-current-buffer (get-buffer-create harness-log-buffer-name)
    (erase-buffer)
    (dotimes (_ 4000) (insert payload "\n")))
  (garbage-collect)
  (princ (format "seed=%d entries=%d payload=%d compiled=%S\n"
                 (buffer-size (get-buffer harness-log-buffer-name)) entries
                 (length payload) (byte-code-function-p (symbol-function 'harness-log))))
  (princ (format "wall-seconds,gcs,gc-seconds=%S\n"
                 (benchmark-run 1 (dotimes (_ entries) (harness-log 'info "%s" payload))))))
