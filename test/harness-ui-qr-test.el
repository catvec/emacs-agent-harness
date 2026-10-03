;;; harness-ui-qr-test.el --- Tests for the QR code encoder  -*- lexical-binding: t; -*-

;;; Commentary:

;; The parts against the standard's own examples (Reed–Solomon, format
;; and version bits), and whole symbols against the reference encoder
;; qrencode: for one text after another, qrencode's matrix is read, the
;; mask it chose taken from its format bits, and the same text encoded
;; here with that mask must give the same modules.

;;; Code:

(require 'harness-test-helpers)

(harness-test-load-module 'ui-qr)

(ert-deftest harness-qr-reed-solomon ()
  "The version 1-M \"HELLO WORLD\" example of the standard."
  (should (equal '(196 35 39 119 235 215 231 226 93 23)
                 (harness-qr--ecc '(32 91 11 120 209 114 220 77 67 64 236 17 236 17 236 17) 10))))

(ert-deftest harness-qr-format-and-version-bits ()
  (should (equal "101010000010010" (harness-qr-test-bits (harness-qr--format-bits 'M 0) 15)))
  (should (equal "110011000101111" (harness-qr-test-bits (harness-qr--format-bits 'L 4) 15)))
  (should (equal "000111110010010100" (harness-qr-test-bits (harness-qr--version-bits 7) 18)))
  (should (equal "101000110001101001" (harness-qr-test-bits (harness-qr--version-bits 40) 18))))

(defun harness-qr-test-binary (n)
  "Return N in binary."
  (if (< n 2) (number-to-string n) (concat (harness-qr-test-binary (ash n -1)) (number-to-string (logand n 1)))))

(defun harness-qr-test-bits (n width)
  "Return N as WIDTH binary digits."
  (let ((s (harness-qr-test-binary n)))
    (concat (make-string (max 0 (- width (length s))) ?0) s)))

(ert-deftest harness-qr-alignment-positions ()
  (should (null (harness-qr--alignment-positions 1)))
  (should (equal '(6 18) (harness-qr--alignment-positions 2)))
  (should (equal '(6 22 38) (harness-qr--alignment-positions 7)))
  (should (equal '(6 34 60 86 112 138) (harness-qr--alignment-positions 32)))
  (should (equal '(6 30 58 86 114 142 170) (harness-qr--alignment-positions 40))))

;;;; Against qrencode

(defun harness-qr-test-reference (text level)
  "Return qrencode's matrix of TEXT at LEVEL: a vector of bool-vectors."
  (with-temp-buffer
    (let ((coding-system-for-write 'utf-8) (coding-system-for-read 'utf-8))
      (unless (zerop (call-process "qrencode" nil t nil "-8" "-l" (symbol-name level) "-m" "0"
                                   "-t" "ASCII" "-o" "-" text))
        (error "qrencode failed: %s" (buffer-string))))
    (vconcat (mapcar (lambda (line)
                       (let* ((n (/ (length line) 2)) (row (make-bool-vector n nil)))
                         (dotimes (i n) (aset row i (eq (aref line (* 2 i)) ?#)))
                         row))
                     (split-string (buffer-string) "\n" t)))))

(defun harness-qr-test-mask-of (rows level)
  "Return the mask the format bits of ROWS (at LEVEL) say."
  (let ((bits 0))
    ;; The first copy, bits 14 down to 0, as `harness-qr--draw-format' lays it.
    (let ((read (lambda (x y) (if (aref (aref rows y) x) 1 0))))
      (dotimes (i 6) (setq bits (logior bits (ash (funcall read 8 i) i))))
      (setq bits (logior bits (ash (funcall read 8 7) 6)))
      (setq bits (logior bits (ash (funcall read 8 8) 7)))
      (setq bits (logior bits (ash (funcall read 7 8) 8)))
      (cl-loop for i from 9 below 15 do (setq bits (logior bits (ash (funcall read (- 14 i) 8) i)))))
    (or (cl-loop for mask from 0 to 7
                 when (= bits (harness-qr--format-bits level mask)) return mask)
        (error "No mask matches the format bits %d" bits))))

(defun harness-qr-test-same-as-qrencode (text level)
  "Check that TEXT at LEVEL gives qrencode's symbol."
  (let* ((reference (harness-qr-test-reference text level))
         (mask (harness-qr-test-mask-of reference level))
         (ours (harness-qr-encode text level mask)))
    (should (= (length reference) (plist-get ours :size)))
    (should (= (plist-get ours :size) (plist-get (harness-qr-encode text level) :size)))
    (unless (equal reference (plist-get ours :modules))
      (ert-fail (list "Modules differ from qrencode's" :text (harness-truncate-end text 60)
                      :level level :version (plist-get ours :version) :mask mask)))))

(defun harness-qr-test-capacity (version level)
  "Return how many bytes VERSION holds at LEVEL in byte mode."
  (- (harness-qr--data-codewords version level) 1 (if (<= version 9) 1 2)))

(ert-deftest harness-qr-matches-qrencode ()
  (skip-unless (executable-find "qrencode"))
  (dolist (text (list "a" "HELLO WORLD" "http://192.168.1.23:4276/pair?code=abcdefghij2345678901"
                      "pair ✓ with Émacs — ok" (make-string 100 ?x) (make-string 150 ?q)
                      (make-string 300 ?z) (mapconcat #'number-to-string (number-sequence 1 400) " ")))
    (harness-qr-test-same-as-qrencode text 'M))
  ;; Every version, at its capacity and one byte over.
  (dolist (version (number-sequence 1 40))
    (let ((n (harness-qr-test-capacity version 'M)))
      (harness-qr-test-same-as-qrencode (substring (mapconcat #'number-to-string (number-sequence 1 n) "") 0 n) 'M)
      (when (< version 40)
        (let ((over (substring (mapconcat #'number-to-string (number-sequence 1 (1+ n)) "") 0 (1+ n))))
          (should (= (1+ version) (plist-get (harness-qr-encode over 'M) :version)))))))
  ;; The other levels.
  (dolist (level '(L Q H))
    (dolist (text (list "http://10.0.0.7:4276/pair?code=mfrggzdfmztwq2lknnwg" (make-string 500 ?k)))
      (harness-qr-test-same-as-qrencode text level))
    (dolist (version '(1 9 10 27 40))
      (harness-qr-test-same-as-qrencode (make-string (harness-qr-test-capacity version level) ?m) level))))

(ert-deftest harness-qr-chooses-the-lowest-penalty ()
  (let* ((text "http://192.168.1.23:4276/pair?code=abcdefghij2345678901")
         (chosen (harness-qr-encode text))
         (penalties (cl-loop for mask from 0 to 7
                             collect (let ((qr (harness-qr-encode text 'M mask)))
                                       (harness-qr--penalty
                                        (harness-qr--make-matrix :size (plist-get qr :size)
                                                                 :modules (plist-get qr :modules)))))))
    (should (= (nth (plist-get chosen :mask) penalties) (apply #'min penalties)))))

(ert-deftest harness-qr-too-long ()
  (should-error (harness-qr-encode (make-string 3000 ?a) 'M)))

(ert-deftest harness-qr-speed ()
  "Encoding a pairing link is cheap on the main thread.
The cost is the processor time Emacs spends, not the time on the clock,
which a busy machine stretches however cheap the work is."
  (let ((url "http://192.168.100.200:4276/pair?code=abcdefghij2345678901&with=more&characters=to-make-it-longer-than-usual")
        (start (float-time (get-internal-run-time))))
    (dotimes (_ 20) (harness-qr-encode url))
    (should (< (- (float-time (get-internal-run-time)) start) 1.0))))

;;;; Drawing

(ert-deftest harness-qr-image-is-one-path ()
  (let* ((qr (harness-qr-encode "hello"))
         (image (harness-qr-image qr 5 4))
         (svg (plist-get (cdr image) :data)))
    (should (eq 'image (car image)))
    (should (= 1 (harness-qr-test-count "<path" svg)))
    (should (string-match-p (format "width=\"%d\"" (* 5 (+ 21 8))) svg))
    (should (string-match-p "viewBox=\"0 0 29 29\"" svg))))

(defun harness-qr-test-count (regexp string)
  "Count the matches of REGEXP in STRING."
  (let ((n 0) (start 0))
    (while (string-match regexp string start)
      (setq n (1+ n) start (match-end 0)))
    n))

(ert-deftest harness-qr-insert ()
  (with-temp-buffer
    (let ((harness-qr-force-text t))
      (harness-qr-insert "hello" :margin 4)
      (let ((lines (split-string (buffer-string) "\n" t)))
        (should (= (ceiling 29 2) (length lines)))
        (dolist (line lines) (should (= 29 (length line))))
        (should (eq 'harness-qr-text-face (get-text-property 1 'face)))
        ;; The quiet zone is light, the finder's corner dark.
        (should (string-match-p "\\` +\\'" (car lines)))
        (should (memq (aref (nth 2 lines) 4) '(?█ ?▀ ?▄)))))
    ;; Indented, the quiet zone keeps its light face: only the indent is plain.
    (erase-buffer)
    (let ((harness-qr-force-text t))
      (harness-qr-insert "hello" :indent 3)
      (goto-char (point-min))
      (dotimes (_ 3)
        (should (null (get-text-property (point) 'face)))
        (should (= (+ 3 29) (- (line-end-position) (line-beginning-position))))
        (should (eq 'harness-qr-text-face (get-text-property (+ (point) 3) 'face)))
        (should (eq 'harness-qr-text-face (get-text-property (+ (point) 31) 'face)))
        (forward-line 1))))
  (with-temp-buffer
    (let ((harness-qr-force-text nil))
      (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t)))
        (harness-qr-insert "hello")
        (should (eq 'image (car (get-text-property (point-min) 'display))))))))

(provide 'harness-ui-qr-test)
;;; harness-ui-qr-test.el ends here
