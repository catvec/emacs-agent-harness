;;; live-profile.el --- profile redraws of the shown session list in the GUI frame  -*- lexical-binding: t; -*-

;; (live-profile N) in the dev harness, after live-check.el filled the
;; session cache: profile N redraws of `*harness sessions*' shown in the GUI
;; frame and return the report (share of each function, GC counters).

(require 'cl-lib)
(require 'profiler)

(defun live-profile (&optional n)
  "Profile N redraws of the session list shown in the GUI frame; return a report string."
  (let* ((gui (car (cl-remove-if-not (lambda (f) (frame-parameter f 'window-system)) (frame-list))))
         (n (or n 5)))
    (select-frame gui)
    (let ((window (or (get-buffer-window "*harness sessions*" gui)
                      (progn (ignore-errors (delete-other-windows))
                             (switch-to-buffer (get-buffer "*harness sessions*"))
                             (selected-window)))))
      (select-window window))
    (harness-ui-sessions--redraw)
    (setq profiler-sampling-interval 1000000)
    (let ((c0 (memory-use-counts)) (g0 gcs-done) (ge0 gc-elapsed) (t0 (float-time)))
      (profiler-start 'cpu)
      (dotimes (_ n) (harness-ui-sessions--redraw))
      (profiler-stop)
      (let* ((took (/ (- (float-time) t0) n))
             (c1 (memory-use-counts))
             (log profiler-cpu-log)
             (incl (make-hash-table :test 'equal)) (self (make-hash-table :test 'equal)) (total 0))
        (maphash (lambda (stack count)
                   (let ((seen nil) (first t))
                     (cl-incf total count)
                     (mapc (lambda (f)
                             (let ((name (if (symbolp f) (symbol-name f) (format "%.60S" f))))
                               (when first (puthash name (+ count (gethash name self 0)) self) (setq first nil))
                               (unless (member name seen)
                                 (push name seen)
                                 (puthash name (+ count (gethash name incl 0)) incl))))
                           (append stack nil))))
                 log)
        (cl-flet ((top (table k)
                    (let (r) (maphash (lambda (key v) (push (cons key v) r)) table)
                         (mapconcat (lambda (c) (format "  %5.1f%% %s" (* 100.0 (/ (cdr c) (float total))) (car c)))
                                    (seq-take (sort r (lambda (a b) (> (cdr a) (cdr b)))) k) "\n"))))
          (format "%d redraws, %.0f ms each, %d conses, %d string-chars, %d GCs (%.2fs)\ninclusive:\n%s\nself:\n%s\n"
                  n (* 1000 took) (/ (- (nth 0 c1) (nth 0 c0)) n) (/ (- (nth 4 c1) (nth 4 c0)) n)
                  (- gcs-done g0) (- gc-elapsed ge0)
                  (top incl 40) (top self 22)))))))

(provide 'live-profile)
