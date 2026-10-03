;;; harness-ui-qr.el --- QR codes, drawn in a buffer  -*- lexical-binding: t; -*-

;;; Commentary:

;; A QR code encoder (ISO/IEC 18004) and two ways to show its result:
;; an SVG image, or Unicode half blocks where a frame shows no images.
;; The remote control page uses it for the link that pairs a phone.
;;
;; `harness-qr-encode' takes a string and returns the matrix: byte mode
;; (the text's UTF-8 bytes), versions 1 to 40, error correction level L,
;; M, Q or H, and the mask of the lowest penalty unless one is forced.
;; `harness-qr-image' draws it as one SVG path, black on white whatever
;; the theme, since scanners want dark modules on a light ground;
;; `harness-qr-insert' inserts it at point.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'svg)
(require 'harness-core)

(defvar harness-qr-force-text nil
  "Non-nil draws QR codes with text characters even where images show.")

;;;; Tables

(defconst harness-qr--ecc-per-block
  [[nil 7 10 15 20 26 18 20 24 30 18 20 24 26 30 22 24 28 30 28 28 28 28 30 30 26 28 30 30 30 30 30 30 30 30 30 30 30 30 30 30]
   [nil 10 16 26 18 24 16 18 22 22 26 30 22 22 24 24 28 28 26 26 26 26 28 28 28 28 28 28 28 28 28 28 28 28 28 28 28 28 28 28 28]
   [nil 13 22 18 26 18 24 18 22 20 24 28 26 24 20 30 24 28 28 26 30 28 30 30 30 30 28 30 30 30 30 30 30 30 30 30 30 30 30 30 30]
   [nil 17 28 22 16 22 28 26 26 24 28 24 28 22 24 24 30 28 28 26 28 30 24 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30]]
  "Error correction codewords per block, by level (L M Q H) then version.")

(defconst harness-qr--blocks
  [[nil 1 1 1 1 1 2 2 2 2 4 4 4 4 4 6 6 6 6 7 8 8 9 9 10 12 12 12 13 14 15 16 17 18 19 19 20 21 22 24 25]
   [nil 1 1 1 2 2 4 4 4 5 5 5 8 9 9 10 10 11 13 14 16 17 17 18 20 21 23 25 26 28 29 31 33 35 37 38 40 43 45 47 49]
   [nil 1 1 2 2 4 4 6 6 8 8 8 10 12 16 12 17 16 18 21 20 23 23 25 27 29 34 34 35 38 40 43 45 48 51 53 56 59 62 65 68]
   [nil 1 1 2 4 4 4 5 6 8 8 11 11 16 16 18 16 19 21 25 25 25 34 30 32 35 37 40 42 45 48 51 54 57 60 63 66 70 74 77 81]]
  "Error correction blocks, by level (L M Q H) then version.")

(defun harness-qr--level-index (level)
  "Return the table row of LEVEL, one of the symbols L M Q H."
  (pcase level ('L 0) ('M 1) ('Q 2) ('H 3) (_ (error "Unknown error correction level %S" level))))

(defun harness-qr--level-bits (level)
  "Return the two format bits of LEVEL."
  (pcase level ('L 1) ('M 0) ('Q 3) ('H 2)))

(defun harness-qr--raw-modules (version)
  "Return the number of modules of VERSION left for data and error correction."
  (let ((n (+ (* (+ (* 16 version) 128) version) 64)))
    (when (>= version 2)
      (let ((align (+ (/ version 7) 2)))
        (setq n (- n (- (* (- (* 25 align) 10) align) 55)))
        (when (>= version 7) (setq n (- n 36)))))
    n))

(defun harness-qr--data-codewords (version level)
  "Return how many data codewords VERSION holds at LEVEL."
  (let ((i (harness-qr--level-index level)))
    (- (/ (harness-qr--raw-modules version) 8)
       (* (aref (aref harness-qr--ecc-per-block i) version)
          (aref (aref harness-qr--blocks i) version)))))

(defun harness-qr--alignment-positions (version)
  "Return the centre coordinates of the alignment patterns of VERSION."
  (if (= version 1)
      nil
    (let* ((count (+ (/ version 7) 2))
           (size (+ (* version 4) 17))
           (step (if (= version 32) 26
                   (* 2 (/ (+ (* version 4) (* count 2) 1) (- (* count 2) 2)))))
           (positions nil)
           (pos (- size 7)))
      (dotimes (_ (1- count))
        (push pos positions)
        (setq pos (- pos step)))
      (cons 6 positions))))

;;;; Galois field and Reed–Solomon

(defconst harness-qr--exp
  (let ((v (make-vector 512 0)) (x 1))
    (dotimes (i 255)
      (aset v i x)
      (setq x (ash x 1))
      (when (>= x 256) (setq x (logxor x #x11d))))
    (dotimes (i 257) (aset v (+ 255 i) (aref v i)))
    v)
  "Powers of 2 in GF(256) with the polynomial 0x11D, twice over.")

(defconst harness-qr--log
  (let ((v (make-vector 256 0)))
    (dotimes (i 255) (aset v (aref harness-qr--exp i) i))
    v)
  "Logarithms in GF(256), the inverse of `harness-qr--exp'.")

(defun harness-qr--mul (x y)
  "Multiply X and Y in GF(256)."
  (if (or (zerop x) (zerop y)) 0
    (aref harness-qr--exp (+ (aref harness-qr--log x) (aref harness-qr--log y)))))

(defun harness-qr--divisor (degree)
  "Return the Reed–Solomon generator polynomial of DEGREE, highest term dropped."
  (let ((result (make-vector degree 0)) (root 1))
    (aset result (1- degree) 1)
    (dotimes (_ degree)
      (dotimes (j degree)
        (aset result j (harness-qr--mul (aref result j) root))
        (when (< (1+ j) degree)
          (aset result j (logxor (aref result j) (aref result (1+ j))))))
      (setq root (harness-qr--mul root 2)))
    result))

(defun harness-qr--ecc (data degree)
  "Return the DEGREE error correction codewords of the block DATA, a list."
  (let ((divisor (harness-qr--divisor degree))
        (result (make-vector degree 0)))
    (dolist (byte data)
      (let ((factor (logxor byte (aref result 0))))
        (dotimes (i (1- degree)) (aset result i (aref result (1+ i))))
        (aset result (1- degree) 0)
        (dotimes (i degree)
          (aset result i (logxor (aref result i) (harness-qr--mul (aref divisor i) factor))))))
    (append result nil)))

;;;; Data codewords

(defun harness-qr--codewords (bytes version level)
  "Return the data codewords of BYTES in byte mode for VERSION at LEVEL, a list."
  (let* ((capacity (* 8 (harness-qr--data-codewords version level)))
         (bits nil)
         (count 0)
         (add (lambda (value width)
                (dotimes (i width)
                  (push (/= 0 (logand value (ash 1 (- width 1 i)))) bits))
                (setq count (+ count width)))))
    (funcall add 4 4)
    (funcall add (length bytes) (if (<= version 9) 8 16))
    (dotimes (i (length bytes)) (funcall add (aref bytes i) 8))
    (funcall add 0 (min 4 (- capacity count)))
    (funcall add 0 (% (- 8 (% count 8)) 8))
    (let ((pad #xec))
      (while (< count capacity)
        (funcall add pad 8)
        (setq pad (if (= pad #xec) #x11 #xec))))
    (let ((bits (nreverse bits)) (out nil))
      (while bits
        (let ((byte 0))
          (dotimes (_ 8) (setq byte (logior (ash byte 1) (if (pop bits) 1 0))))
          (push byte out)))
      (nreverse out))))

(defun harness-qr--interleave (data version level)
  "Return DATA, the data codewords, split in blocks with their EC, interleaved."
  (let* ((i (harness-qr--level-index level))
         (blocks (aref (aref harness-qr--blocks i) version))
         (ecc (aref (aref harness-qr--ecc-per-block i) version))
         (raw (/ (harness-qr--raw-modules version) 8))
         (short-count (- blocks (% raw blocks)))
         (short-len (/ raw blocks))
         (data-blocks nil)
         (ecc-blocks nil))
    (dotimes (b blocks)
      (let ((n (+ (- short-len ecc) (if (< b short-count) 0 1)))
            (block nil))
        (dotimes (_ n) (push (pop data) block))
        (setq block (nreverse block))
        (push (vconcat block) data-blocks)
        (push (vconcat (harness-qr--ecc block ecc)) ecc-blocks)))
    (setq data-blocks (nreverse data-blocks) ecc-blocks (nreverse ecc-blocks))
    (let ((out nil))
      (dotimes (k (1+ (- short-len ecc)))
        (dolist (block data-blocks)
          (when (< k (length block)) (push (aref block k) out))))
      (dotimes (k ecc)
        (dolist (block ecc-blocks) (push (aref block k) out)))
      (nreverse out))))

;;;; The matrix

(cl-defstruct (harness-qr--matrix (:constructor harness-qr--make-matrix) (:copier nil))
  "A QR code under construction."
  size modules function)

(defun harness-qr--new-matrix (size)
  "Return an empty matrix of SIZE by SIZE modules."
  (let ((rows (make-vector size nil)) (fun (make-vector size nil)))
    (dotimes (y size)
      (aset rows y (make-bool-vector size nil))
      (aset fun y (make-bool-vector size nil)))
    (harness-qr--make-matrix :size size :modules rows :function fun)))

(defsubst harness-qr--get (m x y)
  "Return the module at column X, row Y of M."
  (aref (aref (harness-qr--matrix-modules m) y) x))

(defun harness-qr--set-function (m x y dark)
  "Make the module at column X, row Y of M a function module, DARK or light."
  (aset (aref (harness-qr--matrix-modules m) y) x dark)
  (aset (aref (harness-qr--matrix-function m) y) x t))

(defun harness-qr--draw-finder (m cx cy)
  "Draw a finder pattern of M centred at CX, CY, with its separator."
  (let ((size (harness-qr--matrix-size m)))
    (cl-loop for dy from -4 to 4 do
             (cl-loop for dx from -4 to 4 do
                      (let ((x (+ cx dx)) (y (+ cy dy))
                            (dist (max (abs dx) (abs dy))))
                        (when (and (<= 0 x (1- size)) (<= 0 y (1- size)))
                          (harness-qr--set-function m x y (not (memq dist '(2 4))))))))))

(defun harness-qr--draw-alignment (m cx cy)
  "Draw an alignment pattern of M centred at CX, CY."
  (cl-loop for dy from -2 to 2 do
           (cl-loop for dx from -2 to 2 do
                    (harness-qr--set-function m (+ cx dx) (+ cy dy) (/= 1 (max (abs dx) (abs dy)))))))

(defun harness-qr--format-bits (level mask)
  "Return the 15 format information bits for LEVEL and MASK."
  (let* ((data (logior (ash (harness-qr--level-bits level) 3) mask))
         (rem data))
    (dotimes (_ 10)
      (setq rem (logxor (ash rem 1) (* (ash rem -9) #x537))))
    (logxor (logior (ash data 10) rem) #x5412)))

(defun harness-qr--version-bits (version)
  "Return the 18 version information bits of VERSION."
  (let ((rem version))
    (dotimes (_ 12)
      (setq rem (logxor (ash rem 1) (* (ash rem -11) #x1f25))))
    (logior (ash version 12) rem)))

(defun harness-qr--draw-format (m level mask)
  "Draw both copies of the format information of LEVEL and MASK on M."
  (let ((bits (harness-qr--format-bits level mask))
        (size (harness-qr--matrix-size m)))
    (cl-flet ((bit (i) (/= 0 (logand bits (ash 1 i)))))
      (dotimes (i 6) (harness-qr--set-function m 8 i (bit i)))
      (harness-qr--set-function m 8 7 (bit 6))
      (harness-qr--set-function m 8 8 (bit 7))
      (harness-qr--set-function m 7 8 (bit 8))
      (cl-loop for i from 9 below 15 do (harness-qr--set-function m (- 14 i) 8 (bit i)))
      (dotimes (i 8) (harness-qr--set-function m (- size 1 i) 8 (bit i)))
      (cl-loop for i from 8 below 15 do (harness-qr--set-function m 8 (+ (- size 15) i) (bit i)))
      ;; The dark module.
      (harness-qr--set-function m 8 (- size 8) t))))

(defun harness-qr--draw-function-patterns (m version level)
  "Draw every function pattern of VERSION on M, the format for LEVEL with mask 0."
  (let* ((size (harness-qr--matrix-size m))
         (positions (harness-qr--alignment-positions version))
         (last (1- (length positions))))
    (dotimes (i size)
      (harness-qr--set-function m 6 i (cl-evenp i))
      (harness-qr--set-function m i 6 (cl-evenp i)))
    (harness-qr--draw-finder m 3 3)
    (harness-qr--draw-finder m (- size 4) 3)
    (harness-qr--draw-finder m 3 (- size 4))
    (cl-loop for i from 0 to last do
             (cl-loop for j from 0 to last do
                      (unless (or (and (= i 0) (= j 0)) (and (= i 0) (= j last)) (and (= i last) (= j 0)))
                        (harness-qr--draw-alignment m (nth i positions) (nth j positions)))))
    (harness-qr--draw-format m level 0)
    (when (>= version 7)
      (let ((bits (harness-qr--version-bits version)))
        (dotimes (i 18)
          (let ((dark (/= 0 (logand bits (ash 1 i))))
                (a (+ (- size 11) (% i 3)))
                (b (/ i 3)))
            (harness-qr--set-function m a b dark)
            (harness-qr--set-function m b a dark)))))))

(defun harness-qr--draw-codewords (m codewords)
  "Place CODEWORDS, a list of bytes, in the data modules of M."
  (let* ((size (harness-qr--matrix-size m))
         (data (vconcat codewords))
         (total (* 8 (length data)))
         (fun (harness-qr--matrix-function m))
         (rows (harness-qr--matrix-modules m))
         (i 0)
         (right (1- size)))
    (while (>= right 1)
      (when (= right 6) (setq right 5))
      (dotimes (vert size)
        (dotimes (j 2)
          (let* ((x (- right j))
                 (upward (zerop (logand (1+ right) 2)))
                 (y (if upward (- size 1 vert) vert)))
            (when (and (not (aref (aref fun y) x)) (< i total))
              (aset (aref rows y) x
                    (/= 0 (logand (aref data (ash i -3)) (ash 1 (- 7 (logand i 7))))))
              (setq i (1+ i))))))
      (setq right (- right 2)))))

(defun harness-qr--mask-p (mask x y)
  "Non-nil when MASK inverts the module at column X, row Y."
  (pcase mask
    (0 (zerop (% (+ x y) 2)))
    (1 (zerop (% y 2)))
    (2 (zerop (% x 3)))
    (3 (zerop (% (+ x y) 3)))
    (4 (zerop (% (+ (/ x 3) (/ y 2)) 2)))
    (5 (zerop (+ (% (* x y) 2) (% (* x y) 3))))
    (6 (zerop (% (+ (% (* x y) 2) (% (* x y) 3)) 2)))
    (_ (zerop (% (+ (% (+ x y) 2) (% (* x y) 3)) 2)))))

(defun harness-qr--apply-mask (m mask)
  "XOR MASK onto the data modules of M (applying it twice undoes it)."
  (let ((size (harness-qr--matrix-size m))
        (fun (harness-qr--matrix-function m))
        (rows (harness-qr--matrix-modules m)))
    (dotimes (y size)
      (let ((row (aref rows y)) (frow (aref fun y)))
        (dotimes (x size)
          (when (and (not (aref frow x)) (harness-qr--mask-p mask x y))
            (aset row x (not (aref row x)))))))))

;;;; Penalty

(defun harness-qr--finder-count (history)
  "Count the finder-like patterns ending in run HISTORY, a vector of 7 runs."
  (let* ((n (aref history 1))
         (core (and (> n 0) (= (aref history 2) n) (= (aref history 3) (* 3 n))
                    (= (aref history 4) n) (= (aref history 5) n))))
    (+ (if (and core (>= (aref history 0) (* 4 n)) (>= (aref history 6) n)) 1 0)
       (if (and core (>= (aref history 6) (* 4 n)) (>= (aref history 0) n)) 1 0))))

(defun harness-qr--history-add (run history size)
  "Push RUN onto the run HISTORY, counting the border before the first run."
  (when (zerop (aref history 0)) (setq run (+ run size)))
  (cl-loop for i from 6 downto 1 do (aset history i (aref history (1- i))))
  (aset history 0 run))

(defun harness-qr--line-penalty (get size)
  "Return the penalty of SIZE lines read with GET, (LINE INDEX) → module.
Rule 1 (runs of five or more) and rule 3 (finder-like patterns)."
  (let ((score 0))
    (dotimes (line size)
      (let ((color nil) (run 0) (history (make-vector 7 0)))
        (dotimes (i size)
          (if (eq (funcall get line i) color)
              (progn (setq run (1+ run))
                     (cond ((= run 5) (setq score (+ score 3)))
                           ((> run 5) (setq score (1+ score)))))
            (harness-qr--history-add run history size)
            (unless color
              (setq score (+ score (* 40 (harness-qr--finder-count history)))))
            (setq color (funcall get line i) run 1)))
        ;; The light border after the last run.
        (when color
          (harness-qr--history-add run history size)
          (setq run 0))
        (harness-qr--history-add (+ run size) history size)
        (setq score (+ score (* 40 (harness-qr--finder-count history))))))
    score))

(defun harness-qr--penalty (m)
  "Return the penalty score of M (ISO/IEC 18004 §7.8.3)."
  (let* ((size (harness-qr--matrix-size m))
         (rows (harness-qr--matrix-modules m))
         (score (+ (harness-qr--line-penalty (lambda (y x) (aref (aref rows y) x)) size)
                   (harness-qr--line-penalty (lambda (x y) (aref (aref rows y) x)) size)))
         (dark 0))
    (dotimes (y size)
      (let ((row (aref rows y)))
        (dotimes (x size)
          (when (aref row x) (setq dark (1+ dark)))
          (when (and (< x (1- size)) (< y (1- size)))
            (let ((c (aref row x)) (below (aref rows (1+ y))))
              (when (and (eq c (aref row (1+ x))) (eq c (aref below x)) (eq c (aref below (1+ x))))
                (setq score (+ score 3))))))))
    (let* ((total (* size size))
           (k (1- (ceiling (abs (- (* dark 20) (* total 10))) total))))
      (+ score (* 10 (max 0 k))))))

;;;; Encoding

(defun harness-qr--version-for (bytes level)
  "Return the smallest version that holds BYTES at LEVEL."
  (or (cl-loop for version from 1 to 40
               when (<= (+ 4 (if (<= version 9) 8 16) (* 8 (length bytes)))
                        (* 8 (harness-qr--data-codewords version level)))
               return version)
      (error "Text too long for a QR code: %d bytes" (length bytes))))

(defun harness-qr--matrix-penalty (m mask level)
  "Return the penalty of M with MASK applied, leaving M as it was."
  (harness-qr--apply-mask m mask)
  (harness-qr--draw-format m level mask)
  (prog1 (harness-qr--penalty m)
    (harness-qr--apply-mask m mask)))

(defun harness-qr-encode (text &optional level mask)
  "Encode TEXT as a QR code and return (:size :version :level :mask :modules).
TEXT's UTF-8 bytes go in byte mode, at error correction LEVEL (the
symbol L, M, Q or H, default M), in the smallest version that holds
them.  MASK, 0 to 7, forces a mask; by default the one with the lowest
penalty is used.  :modules is a vector of rows, top first, each a
bool-vector whose t are dark modules."
  (let* ((level (or level 'M))
         (bytes (encode-coding-string text 'utf-8 t))
         (version (harness-qr--version-for bytes level))
         (size (+ (* version 4) 17))
         (m (harness-qr--new-matrix size)))
    (harness-qr--draw-function-patterns m version level)
    (harness-qr--draw-codewords
     m (harness-qr--interleave (harness-qr--codewords bytes version level) version level))
    (let ((mask (or mask
                    (let (best best-score)
                      (dotimes (candidate 8)
                        (let ((score (harness-qr--matrix-penalty m candidate level)))
                          (when (or (null best-score) (< score best-score))
                            (setq best candidate best-score score))))
                      best))))
      (harness-qr--apply-mask m mask)
      (harness-qr--draw-format m level mask)
      (list :size size :version version :level level :mask mask
            :modules (harness-qr--matrix-modules m)))))

;;;; Drawing

(defun harness-qr--path (qr margin)
  "Return the SVG path drawing the dark modules of QR, MARGIN modules in."
  (let ((rows (plist-get qr :modules))
        (size (plist-get qr :size))
        (parts nil))
    (dotimes (y size)
      (let ((row (aref rows y)) (x 0))
        (while (< x size)
          (if (not (aref row x))
              (setq x (1+ x))
            (let ((start x))
              (while (and (< x size) (aref row x)) (setq x (1+ x)))
              (push (format "M%d %dh%dv1h-%dz" (+ start margin) (+ y margin) (- x start) (- x start))
                    parts))))))
    (apply #'concat (nreverse parts))))

(defun harness-qr-image (qr &optional scale margin)
  "Return an SVG image of QR, as `harness-qr-encode' returns it.
Black modules on white, MARGIN modules of quiet zone (default 4) and
SCALE pixels per module (default from the frame's line height)."
  (let* ((margin (or margin 4))
         (scale (or scale (max 3 (round (/ (default-font-height) 3.0)))))
         (modules (+ (plist-get qr :size) (* 2 margin)))
         (pixels (* modules scale))
         (svg (svg-create pixels pixels :viewBox (format "0 0 %d %d" modules modules)
                          :shape-rendering "crispEdges")))
    (svg-rectangle svg 0 0 modules modules :fill "#ffffff")
    (svg-node svg 'path :d (harness-qr--path qr margin) :fill "#000000")
    (svg-image svg :ascent 'center)))

(defface harness-qr-text-face '((t :foreground "black" :background "white"))
  "QR codes drawn with text characters: dark on light whatever the theme."
  :group 'harness-ui)

(defun harness-qr--insert-text (qr margin &optional indent)
  "Insert QR drawn with half blocks, MARGIN modules of quiet zone around it.
Each line starts with INDENT spaces, outside the code."
  (let* ((rows (plist-get qr :modules))
         (size (plist-get qr :size))
         (width (+ size (* 2 margin)))
         (dark (lambda (x y)
                 (let ((x (- x margin)) (y (- y margin)))
                   (and (<= 0 x (1- size)) (<= 0 y (1- size)) (aref (aref rows y) x))))))
    (cl-loop for y from 0 below width by 2 do
             (insert (make-string (or indent 0) ?\s))
             (insert (propertize
                      (apply #'string
                             (cl-loop for x from 0 below width
                                      collect (let ((top (funcall dark x y))
                                                    (bottom (funcall dark x (1+ y))))
                                                (cond ((and top bottom) ?█)
                                                      (top ?▀)
                                                      (bottom ?▄)
                                                      (t ?\s)))))
                      'face 'harness-qr-text-face)
                     "\n"))))

(cl-defun harness-qr-insert (text &key (level 'M) scale margin indent)
  "Insert at point the QR code of TEXT; return the position after it.
An SVG image where this frame shows one, else half-block characters
\(always so with `harness-qr-force-text').  LEVEL is the error
correction level, SCALE pixels per module and MARGIN modules of quiet
zone, as for `harness-qr-image'.  INDENT spaces start every line the
code takes, outside it: indenting the code afterwards would turn the
light spaces of its quiet zone into plain whitespace."
  (let ((qr (harness-qr-encode text level)))
    (if (and (not harness-qr-force-text) (display-images-p) (image-type-available-p 'svg))
        (progn (insert (make-string (or indent 0) ?\s))
               (insert-image (harness-qr-image qr scale margin) "[QR code]"))
      (harness-qr--insert-text qr (or margin 4) indent))
    (point)))

(harness-define-module 'ui-qr
  :doc "QR codes: an encoder, drawn as an SVG image or with text characters.")

(provide 'harness-ui-qr)
;;; harness-ui-qr.el ends here
