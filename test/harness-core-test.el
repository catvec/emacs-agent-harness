;;; harness-core-test.el --- Tests for the module bus  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-http)

(ert-deftest harness-core-methods-roundtrip ()
  (harness-test-reset-bus)
  (harness-register-method 'test/add (lambda (a b) (+ a b)) :doc "add")
  (should (= 3 (harness-call 'test/add 1 2)))
  (should (harness-method-exists-p 'test/add))
  (should-error (harness-call 'test/missing) :type 'harness-no-such-method)
  (should (equal '(:name test/add :doc "add" :module nil :params nil)
                 (car (harness-methods)))))

(ert-deftest harness-core-a-missing-method-signals-and-nothing-answers-for-it ()
  "A method nobody registered signals, here and through the async wrapper.
There is no fallback to answer for it: code in this Emacs reaches the
methods registered in it and no others (a harness in another process is
reached over ACP, as a client does, never through `harness-call')."
  (harness-test-reset-bus)
  (harness-register-method 'test/here (lambda (x) (list 'here x)))
  (should (equal '(here 1) (harness-call 'test/here 1)))
  (should-error (harness-call 'test/away 1 :k 'v) :type 'harness-no-such-method)
  (should-error (harness-await (harness-call-async 'test/away)) :type 'harness-no-such-method)
  (should-not (harness-method-exists-p 'test/away))
  (should-not (boundp 'harness-call-fallback-function)))

(ert-deftest harness-core-call-async-wraps-values-and-errors ()
  (harness-test-reset-bus)
  (harness-register-method 'test/val (lambda () 42))
  (harness-register-method 'test/boom (lambda () (error "boom")))
  (should (= 42 (harness-await (harness-call-async 'test/val))))
  (should-error (harness-await (harness-call-async 'test/boom))))

(ert-deftest harness-core-events-priority-and-isolation ()
  (harness-test-reset-bus)
  (let (log)
    (harness-on 'test/ev (lambda (x) (push (list 'b x) log)) 60)
    (harness-on 'test/ev (lambda (_x) (error "ignored")) 10)
    (harness-on 'test/ev (lambda (x) (push (list 'a x) log)) 20)
    (harness-on '* (lambda (ev args) (push (list 'any ev args) log)))
    (should (= 3 (harness-emit 'test/ev 1)))
    (should (equal '((any test/ev (1)) (b 1) (a 1)) log))))

(ert-deftest harness-core-events-dedupe-and-off ()
  (harness-test-reset-bus)
  (let ((n 0))
    (defalias 'harness-test--counter (lambda () (cl-incf n)))
    (harness-on 'test/ev #'harness-test--counter)
    (let ((h (harness-on 'test/ev #'harness-test--counter)))
      (harness-emit 'test/ev)
      (should (= n 1))
      (harness-off h)
      (harness-emit 'test/ev)
      (should (= n 1)))))

(ert-deftest harness-core-sync-filter ()
  (harness-test-reset-bus)
  (harness-add-filter 'test/f (lambda (v _ctx) (* v 2)) 20)
  (harness-add-filter 'test/f (lambda (v ctx) (+ v ctx)) 10)
  (should (= 8 (harness-run-filter 'test/f 1 3))))

(defun harness-core-test--log-text ()
  "Return the harness log buffer's text."
  (with-current-buffer harness-log-buffer-name (buffer-string)))

(ert-deftest harness-core-log-filter-changes-what-the-log-keeps ()
  "`harness-log-filter-function' filters a message before it is kept or hooked.
Both the buffer and the hook get the filtered text, and the message
`harness-log' returns is that text."
  (let ((harness-log-level 'info)
        (hooked nil)
        (harness-log-filter-function (lambda (msg) (string-replace "hunter2" "[gone]" msg))))
    (with-current-buffer (get-buffer-create harness-log-buffer-name)
      (let ((inhibit-read-only t)) (erase-buffer)))
    (let ((harness-log-hook (list (lambda (_level msg) (push msg hooked)))))
      (should (equal "the password is [gone]" (harness-log 'info "the password is %s" "hunter2"))))
    (should (equal '("the password is [gone]") hooked))
    (should (string-search "INFO  the password is [gone]" (harness-core-test--log-text)))
    (should-not (string-search "hunter2" (harness-core-test--log-text)))
    ;; No filter, no change.
    (let ((harness-log-filter-function nil))
      (should (equal "kept hunter2" (harness-log 'info "kept %s" "hunter2"))))))

(ert-deftest harness-core-log-filter-failing-or-logging-is-harmless ()
  "A filter that signals or answers with no string leaves the message as it was.
One that logs does not filter that message again, so it cannot recurse."
  (let ((harness-log-level 'info))
    (let ((harness-log-filter-function (lambda (_msg) (error "Boom"))))
      (should (equal "still logged" (harness-log 'info "still logged"))))
    (let ((harness-log-filter-function (lambda (_msg) 42)))
      (should (equal "as it was" (harness-log 'info "as it was"))))
    (let* ((calls 0)
           (harness-log-filter-function
            (lambda (msg)
              (cl-incf calls)
              (harness-log 'info "inner %s" msg)
              (concat "filtered " msg))))
      (should (equal "filtered outer" (harness-log 'info "outer")))
      ;; Once for the outer message; the inner one passed unfiltered.
      (should (= 1 calls))
      (should (string-search "INFO  inner outer" (harness-core-test--log-text)))
      (should (string-search "INFO  filtered outer" (harness-core-test--log-text))))
    ;; The guard is released again afterwards.
    (let ((harness-log-filter-function #'upcase))
      (should (equal "AGAIN" (harness-log 'info "again"))))))

(ert-deftest harness-core-async-filter-chain-and-final ()
  (harness-test-reset-bus)
  (harness-add-filter 'test/af (lambda (v next) (run-at-time 0.01 nil next (plist-put v :a t))) 10)
  (harness-add-filter 'test/af (lambda (v next) (funcall next (plist-put v :b t))) 20)
  (harness-add-filter 'test/af (lambda (v _next) (harness-resolved (plist-put v :c t))) 30)
  (let ((r (harness-await (harness-run-filter-async 'test/af (list :start t)))))
    (should (plist-get r :a)) (should (plist-get r :b)) (should (plist-get r :c)))
  ;; :final stops the chain.
  (harness-add-filter 'test/af2 (lambda (v next) (funcall next (plist-put v :final t))) 10)
  (harness-add-filter 'test/af2 (lambda (v next) (funcall next (plist-put v :never t))) 20)
  (should-not (plist-get (harness-await (harness-run-filter-async 'test/af2 nil)) :never)))

(ert-deftest harness-core-async-filter-failures-pass-on-the-value-unless-the-chain-says-otherwise ()
  "A handler that fails hands its value on, but a chain that guards can say no.
Most chains only add to what they carry, and one handler failing leaves
the rest to go on.  A chain that guards (`permission/decide') cannot let
the failure of the handler that would have refused read as nothing to
refuse, so it names what a failure hands on, and that can stop the
chain."
  (harness-test-reset-bus)
  (let ((boom (lambda (_v _next) (error "boom")))
        (rejected (lambda (_v _next) (harness-rejected '(harness-error "rejected"))))
        (after (lambda (v next) (funcall next (plist-put (copy-sequence v) :after t)))))
    ;; By default the failure is skipped, and the chain goes on.
    (dolist (failing (list boom rejected))
      (harness-remove-filter 'test/fail failing)
      (harness-add-filter 'test/fail failing 10)
      (harness-add-filter 'test/fail after 20)
      (let ((r (harness-await (harness-run-filter-async 'test/fail (list :start t)))))
        (should (plist-get r :start))
        (should (plist-get r :after)))
      (harness-remove-filter 'test/fail failing))
    ;; A chain that names what a failure hands on gets that, whichever way
    ;; the handler failed, and a final value stops the chain.
    (let (seen)
      (harness-set-filter-failure
       'test/fail (lambda (value handler err)
                    (push (list value handler (car-safe err)) seen)
                    (list :refused t :final t)))
      (unwind-protect
          (dolist (failing (list boom rejected))
            (harness-add-filter 'test/fail failing 10)
            (let ((r (harness-await (harness-run-filter-async 'test/fail (list :start t)))))
              (should (plist-get r :refused))
              (should-not (plist-get r :after)))
            (harness-remove-filter 'test/fail failing))
        (harness-clear-filter-failure 'test/fail))
      (should (= 2 (length seen)))
      (should (equal '(:start t) (car (nth 0 seen))))
      (should (eq boom (nth 1 (nth 1 seen))))
      (should (eq 'error (nth 2 (nth 1 seen))))
      (should (eq rejected (nth 1 (nth 0 seen)))))
    ;; The failure function must not fail: if it does, the value goes on.
    (harness-set-filter-failure 'test/fail (lambda (&rest _) (error "worse")))
    (unwind-protect
        (progn
          (harness-add-filter 'test/fail boom 10)
          (should (plist-get (harness-await (harness-run-filter-async 'test/fail (list :after t))) :after)))
      (harness-clear-filter-failure 'test/fail))
    ;; And a chain with none is what it was.
    (should-not (gethash 'test/fail harness--filter-failures))))

(ert-deftest harness-core-async-filter-between-runs-some-stages ()
  "`harness-run-filter-async-between' runs the stages whose priority lies
between FROM and TO, both included, in order, with the same arguments,
and `:final' stops it as it stops the whole chain."
  (harness-test-reset-bus)
  (let ((seen nil))
    (dolist (priority '(5 10 20 30 90))
      (let ((priority priority))
        (harness-add-filter 'test/ab (lambda (v next extra)
                                       (push (list priority extra) seen)
                                       (funcall next (plist-put v :last priority)))
                            priority)))
    (should (equal '(:last 30) (harness-await (harness-run-filter-async-between 'test/ab 10 30 nil 'x))))
    (should (equal '((30 x) (20 x) (10 x)) seen))
    (setq seen nil)
    (should (equal '(:start t) (harness-await (harness-run-filter-async-between 'test/ab 40 80 '(:start t) 'y))))
    (should-not seen)
    (should (equal '(:last 90) (harness-await (harness-run-filter-async 'test/ab nil 'z))))
    (should (equal '(90 30 20 10 5) (mapcar #'car seen)))
    (setq seen nil)
    (harness-add-filter 'test/ab (lambda (v next _extra) (funcall next (plist-put v :final t))) 15)
    (should (equal '(:last 10 :final t) (harness-await (harness-run-filter-async-between 'test/ab 6 40 nil 'w))))
    (should (equal '((10 w)) seen))))

(ert-deftest harness-core-async-filter-traced-names-who-changed-the-value ()
  "`harness-run-filter-async-traced' tells its tracer each function that
handed on a value other than the one it got, between FROM and TO; a
function that passes its value on as it is goes unnamed, and a tracer
that fails is logged, not the chain's end."
  (harness-test-reset-bus)
  (let ((traced nil))
    (harness-add-filter 'test/at (lambda (v next _x) (funcall next v)) 5)
    (harness-add-filter 'test/at #'harness-core-test--decides 10)
    (harness-add-filter 'test/at (lambda (v next _x) (funcall next v)) 20)
    (should (equal '(:decided t)
                   (harness-await (harness-run-filter-async-traced
                                   'test/at nil '(x)
                                   :tracer (lambda (fn old new) (push (list fn old new) traced))))))
    (should (equal '((harness-core-test--decides nil (:decided t))) traced))
    ;; Bounds leave the stage out.
    (setq traced nil)
    (should-not (harness-await (harness-run-filter-async-traced
                                'test/at nil '(x) :from 11
                                :tracer (lambda (fn _old _new) (push fn traced)))))
    (should-not traced)
    ;; A failing tracer does not stop the chain.
    (should (equal '(:decided t)
                   (harness-await (harness-run-filter-async-traced
                                   'test/at nil '(x) :tracer (lambda (&rest _) (error "Oops"))))))))

(defun harness-core-test--decides (_value next _x)
  "A filter stage that decides: it hands on a value of its own to NEXT."
  (funcall next (list :decided t)))

(ert-deftest harness-core-promises ()
  (let ((p (harness-make-promise)))
    (should-not (harness-promise-settled-p p))
    (harness-resolve p 1)
    (should (= 2 (harness-await (harness-then p #'1+)))))
  (let ((p (harness-rejected '(error "x"))))
    (should (equal 'recovered (harness-await (harness-then p nil (lambda (_e) 'recovered))))))
  (should (equal '(1 2 3) (harness-await (harness-all (list (harness-resolved 1) 2 (harness-resolved 3))))))
  (let ((p (harness-with-promise (resolve _reject) (run-at-time 0.01 nil resolve 'later))))
    (should (eq 'later (harness-await p))))
  (should-error (harness-await (harness-with-promise (_r _j) (error "inside")))))

(ert-deftest harness-core-promise-chains-do-not-recurse ()
  ;; A long chain of promises resolving one another must not grow the stack.
  (let ((max-lisp-eval-depth 800)
        (p (harness-resolved 0)))
    (dotimes (_ 3000)
      (setq p (harness-then p #'1+)))
    (should (= 3000 (harness-await p))))
  ;; Nested adoption: each promise resolved with the next one.
  (let ((max-lisp-eval-depth 800)
        (head (harness-make-promise)) (cur nil))
    (setq cur head)
    (dotimes (_ 3000)
      (let ((next (harness-make-promise)))
        (harness-resolve cur next)
        (setq cur next)))
    (harness-resolve cur 'end)
    (should (eq 'end (harness-await head)))))

(ert-deftest harness-core-modules-order-and-failure-isolation ()
  (harness-test-reset-bus)
  (let (order)
    (harness-define-module 'c :requires '(b) :init (lambda () (push 'c order)))
    (harness-define-module 'a :init (lambda () (push 'a order)))
    (harness-define-module 'b :requires '(a) :init (lambda () (push 'b order)))
    (harness-define-module 'bad :init (lambda () (error "nope")))
    (harness-define-module 'dep-on-bad :requires '(bad) :init (lambda () (push 'never order)))
    (let ((ready (harness-modules-init)))
      (should (equal '(a b c) (reverse order)))
      (should (equal '(a b c) (sort (copy-sequence ready) (lambda (x y) (string< x y)))))
      (should (eq 'failed (harness-module-state (harness-module-get 'bad))))
      (should (eq 'failed (harness-module-state (harness-module-get 'dep-on-bad)))))
    ;; Redefinition keeps a ready module ready, and the next
    ;; initialisation, as a reload runs, calls the new INIT.
    (harness-define-module 'a :doc "new doc" :init (lambda () (push 'again order)))
    (should (harness-module-ready-p 'a))
    (harness-modules-init)
    (should (memq 'again order))
    (should (harness-module-ready-p 'a))))

(ert-deftest harness-core-module-initialises-again ()
  "A ready module's INIT runs again, and tells a first start from a later one.
A failing INIT keeps a ready module ready, with the error recorded until
it runs cleanly again.  A disabled module stays off."
  (harness-test-reset-bus)
  (let ((runs nil) (fail nil))
    (harness-define-module 'm :init (lambda ()
                                      (push (harness-module-ready-p 'm) runs)
                                      (when fail (error "Broken"))))
    (should (harness-module-start 'm))
    (should (harness-module-start 'm))
    ;; nil the first time, t the second.
    (should (equal '(t nil) runs))
    (setq fail t)
    (should-not (harness-module-start 'm))
    (should (harness-module-ready-p 'm))
    (should (equal "Broken" (plist-get (car (harness-module-descriptions)) :error)))
    (setq fail nil)
    (should (harness-module-start 'm))
    (should-not (harness-module-error (harness-module-get 'm)))
    (harness-module-disable 'm)
    (setq runs nil)
    (harness-modules-init)
    (should-not runs)
    (should (eq 'disabled (harness-module-state (harness-module-get 'm))))))

(ert-deftest harness-core-handlers-move-to-a-new-priority ()
  "Subscribing or filtering with the same function again changes nothing,
but for moving it to the priority given, as a reloaded `:init' gives."
  (harness-test-reset-bus)
  (let (log)
    (defalias 'harness-core-test--early (lambda () (push 'early log)))
    (defalias 'harness-core-test--late (lambda () (push 'late log)))
    (harness-on 'test/ev #'harness-core-test--early 10)
    (harness-on 'test/ev #'harness-core-test--late 20)
    (harness-on 'test/ev #'harness-core-test--early 10)
    (should (= 2 (length (gethash 'test/ev harness--subscribers))))
    (harness-on 'test/ev #'harness-core-test--early 30)
    (should (= 2 (length (gethash 'test/ev harness--subscribers))))
    (harness-emit 'test/ev)
    (should (equal '(early late) log))
    (harness-add-filter 'test/f #'1+ 10)
    (harness-add-filter 'test/f #'1+ 10)
    (should (equal '((10 . 1+)) (gethash 'test/f harness--filters)))
    (harness-add-filter 'test/f #'1+ 40)
    (should (equal '((40 . 1+)) (gethash 'test/f harness--filters)))))

(ert-deftest harness-core-defmethod-records-module ()
  (harness-test-reset-bus)
  (let ((harness--defining-module 'demo))
    (eval '(harness-defmethod test/hello (name) "Say hello." (format "hi %s" name)) t))
  (should (equal "hi x" (harness-call 'test/hello "x")))
  (should (eq 'demo (plist-get (car (harness-methods)) :module))))

(ert-deftest harness-util-json-conventions ()
  (should (equal "{\"a\":1,\"b\":[1,2],\"c\":null,\"d\":false,\"e\":true,\"f\":{},\"g\":[]}"
                 (harness-json-encode '(:a 1 :b (1 2) :c nil :d :false :e t :f :empty :g []))))
  (should (equal '(:a 1 :b (1 2) :c nil :d :false)
                 (harness-json-parse "{\"a\":1,\"b\":[1,2],\"c\":null,\"d\":false}")))
  (should (equal "[{\"x\":1}]" (harness-json-encode '((:x 1)))))
  (should (equal "{\"lines\":[2,30]}" (harness-json-encode '(:lines (2 . 30))))))

(ert-deftest harness-util-json-encode-text ()
  ;; Since Emacs 30 `harness-json-encode' gives bytes, which become raw-byte
  ;; characters inside other text and then cannot be encoded again.  The
  ;; text variant gives characters.
  (let* ((s "\N{U+2717} caf\N{U+E9} \N{U+D7} \N{U+2026}")
         (obj (list :s s))
         (text (harness-json-encode-text obj)))
    (should (multibyte-string-p text))
    (should (equal (concat "{\"s\":\"" s "\"}") text))
    (should (equal obj (harness-json-parse text)))
    ;; The same bytes on the wire either way.
    (should (equal (encode-coding-string text 'utf-8-unix)
                   (encode-coding-string (harness-json-encode obj) 'utf-8-unix)))
    ;; Inside other text, and that text inside other JSON, it stays text.
    (let ((outer (format "Input (JSON):\n%s\nNote: %s" text s)))
      (should (equal outer (plist-get (harness-json-parse (harness-json-encode (list :text outer))) :text)))))
  (should (equal "{\"a\":[1,\"b\"]}" (harness-json-encode-text '(:a (1 "b"))))))

(defun harness-core-test--raw-bytes ()
  "Return \"abc\" + two raw bytes (FF, FE) + \"def\", read into a buffer.
Built in a unibyte buffer, as a process or `cat' of a binary file would
leave it, then switched to multibyte: the two bad bytes come out as
`eight-bit' characters, which `harness-valid-text' repairs.  Two
separate string literals for the two bytes: Lisp's \\=\\x escape takes
as many following hex digits as it can, so a `def' right after it in
the same literal would be read as part of the same character instead."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert "abc\xff\xfe" "def")
    (set-buffer-multibyte t)
    (buffer-string)))

(ert-deftest harness-util-valid-text ()
  "`harness-valid-text' repairs a raw byte and leaves good text alone."
  ;; Multibyte text with no raw byte: unchanged, not even copied.
  (let ((s "caf\N{U+E9} naive unicode \N{U+2717}"))
    (should (eq s (harness-valid-text s))))
  ;; A unibyte string that is plain ASCII: unchanged too.
  (let ((s (string-to-unibyte "plain ascii")))
    (should (eq s (harness-valid-text s))))
  ;; A multibyte string with a raw byte -- binary read as if it were
  ;; text -- loses just that byte, one U+FFFD (\N{U+FFFD}) each, the
  ;; rest intact.
  (should (equal (concat "abc" "\N{U+FFFD}" "\N{U+FFFD}" "def")
                 (harness-valid-text (harness-core-test--raw-bytes))))
  ;; A unibyte string outside ASCII is decoded as UTF-8 first: a
  ;; well-formed run comes back as its real characters...
  (should (equal "a\N{U+E9}" (harness-valid-text (unibyte-string ?a 195 169))))
  ;; ... and what still is not valid becomes U+FFFD, same as above.
  (should (equal (concat "ab" "\N{U+FFFD}" "\N{U+FFFD}")
                 (harness-valid-text (unibyte-string ?a ?b 255 254)))))

(ert-deftest harness-util-valid-text-linear ()
  "`harness-valid-text' repairs a long string with many raw bytes quickly.
With `replace-regexp-in-string' this took time quadratic in the length:
a transcript of a few megabytes wedged the server at startup."
  (let* ((raw (harness-core-test--raw-bytes))
         (s (apply #'concat (make-list 50000 raw)))
         (start (float-time))
         (fixed (harness-valid-text s)))
    (should (< (- (float-time) start) 5))
    (should (= (length fixed) (length s)))
    (should (stringp (json-serialize fixed)))))

(ert-deftest harness-util-json-encode-repairs-raw-bytes ()
  "`harness-json-encode' repairs a raw byte instead of signalling.
`json-serialize' refuses a string with one, `wrong-type-argument'
naming `json-value-p': the whole call would otherwise fail on a value
deep inside OBJ, such as a tool result that read a binary file as if
it were text, leaving whoever asked for the encoding with no answer at
all (see `harness-valid-text')."
  (let* ((raw (harness-core-test--raw-bytes))
         (cleaned (concat "abc" "\N{U+FFFD}" "\N{U+FFFD}" "def"))
         (logged nil)
         (harness-log-hook (list (lambda (_level msg) (push msg logged))))
         (encoded (harness-json-encode (list :content raw :n 1 :nested (list (list :x raw))))))
    (should (stringp encoded))
    (should (equal (list :content cleaned :n 1 :nested (list (list :x cleaned)))
                   (harness-json-parse encoded)))
    ;; Logged, short, so the repair is not silent, but carries none of
    ;; the raw text itself.
    (should (cl-some (lambda (m) (string-match-p "raw byte" m)) logged))
    (should-not (cl-some (lambda (m) (string-match-p "abc" m)) logged)))
  ;; A unibyte string is repaired the same way.
  (should (equal (concat "{\"m\":\"a" "\N{U+FFFD}" "\"}")
                 (harness-json-encode-text (list :m (unibyte-string ?a 255)))))
  ;; Nothing to repair: round-trips as plain JSON, as before.
  (should (equal "{\"a\":1}" (harness-json-encode '(:a 1))))
  ;; A `wrong-type-argument' about something other than `json-value-p'
  ;; still signals rather than being treated as a raw byte to repair.
  (should-error
   (cl-letf (((symbol-function 'json-serialize)
              (lambda (&rest _) (signal 'wrong-type-argument '(sequencep 3)))))
     (harness-json-encode '(:a 1)))
   :type 'wrong-type-argument))

(ert-deftest harness-util-json-parse-long-whitespace ()
  "Parsing takes time linear in a long run of spaces inside the JSON.
The check for empty input used `string-trim', whose time is quadratic in
such a run: tens of seconds for one of 100,000."
  (let ((json (concat "{\"s\":\"x" (make-string 100000 ?\s) "y\"}"))
        (start (float-time)))
    (should (= 100002 (length (plist-get (harness-json-parse json) :s))))
    (should (< (- (float-time) start) 2)))
  (should-not (harness-json-parse " \n\t "))
  (should-not (harness-json-parse nil)))

(ert-deftest harness-util-grep-hit ()
  "A line of grep -H output splits at its file name, however long the line."
  (should (equal '("abc" . "{\"a\":1}")
                 (harness-grep-hit "/state/sessions/abc.nodes.jsonl:{\"a\":1}" ".nodes.jsonl")))
  ;; At the first such name: the text can mention another.
  (should (equal '("abc" . "see x.nodes.jsonl:3")
                 (harness-grep-hit "sessions/abc.nodes.jsonl:see x.nodes.jsonl:3" ".nodes.jsonl")))
  (should-not (harness-grep-hit "Binary file abc.nodes.jsonl matches" ".nodes.jsonl"))
  ;; A line of megabytes, past where a backtracking regexp overflows.
  (let* ((text (concat "{\"output\":\"" (make-string 2000000 ?x) "\"}"))
         (hit (harness-grep-hit (concat "/state/sessions/abc.nodes.jsonl:" text) ".nodes.jsonl")))
    (should (equal "abc" (car hit)))
    (should (equal text (cdr hit)))))

(ert-deftest harness-util-misc ()
  (should (= 36 (length (harness-uuid))))
  (should (equal "12.3k" (harness-format-tokens 12345)))
  (should (equal "1.20M" (harness-format-tokens 1200000)))
  (should (equal "abc…xyz" (harness-truncate-middle "abcdefghijklmnopqrstuvwxyz" 7)))
  (should (harness-path-within-p "/tmp" "/tmp/a/b"))
  (should-not (harness-path-within-p "/tmp/a" "/tmp/ab"))
  (should (harness-fuzzy-score "hcl" "harness-core.el"))
  (should-not (harness-fuzzy-score "zzz" "harness"))
  (should (equal '("harness-core.el" "harness-http.el")
                 (sort (harness-fuzzy-filter "hel" '("readme" "harness-core.el" "harness-http.el"))
                       #'string<))))

(defun harness-core-test--bytes (&rest parts)
  "Return PARTS, strings and byte values, as one unibyte string."
  (apply #'unibyte-string
         (apply #'append (mapcar (lambda (p) (if (stringp p) (append (string-to-unibyte p) nil) (list p))) parts))))

;;;; Remote home directories
;;
;; The permission chain may not connect to a host, so it takes a TRAMP
;; name in a home directory (/ssh:box:~/src) as a place of its own and
;; works on its text.  Everything here runs where a connection attempt
;; fails the test, even one the code under test caught.

(defun harness-core-test--connection-attempts (fn)
  "Call FN where TRAMP cannot connect; return the hosts it tried, oldest first.
Errors FN signals are ignored: the question is only whether it tried."
  (require 'tramp)
  (let (attempts)
    (cl-letf (((symbol-function 'tramp-maybe-open-connection)
               (lambda (vec &rest _)
                 (push (tramp-make-tramp-file-name vec 'noloc) attempts)
                 (error "Nothing may connect"))))
      (ignore-errors (funcall fn)))
    (nreverse attempts)))

(ert-deftest harness-util-connection-guard-catches-a-swallowed-attempt ()
  "The guard of these tests fails a test whose code connected, and plain
Emacs functions do connect for a name in a remote home directory.
That is why the permission chain has functions of its own for them."
  (let ((home "/ssh:u@box.example.invalid:~/x"))
    ;; The functions the chain must not call on such a name.
    (dolist (fn (list (lambda () (expand-file-name home "/"))
                      (lambda () (abbreviate-file-name home))
                      (lambda () (file-truename home))))
      (should (equal '("/ssh:u@box.example.invalid:") (harness-core-test--connection-attempts fn))))
    ;; A name with an absolute local part is only normalised.
    (should-not (harness-core-test--connection-attempts
                 (lambda () (expand-file-name "/ssh:u@box.example.invalid:/var/log/../x" "/"))))
    ;; The guard fails the test even when the attempt was caught.
    (should-error (harness-test-without-connections
                    (ignore-errors (expand-file-name home "/")))
                  :type 'ert-test-failed)
    (should (equal 'fine (harness-test-without-connections 'fine)))))

(ert-deftest harness-util-remote-parts-read-a-name-as-written ()
  "A TRAMP name splits into its prefix, jump hosts and all, and its local
part, a ~ staying a ~; anything that is no TRAMP name has no parts."
  (harness-test-without-connections
    (should (equal '("/ssh:u@box.example.invalid:" . "~/x")
                   (harness-remote-parts "/ssh:u@box.example.invalid:~/x")))
    (should (equal '("/ssh:u@box.example.invalid:" . "")
                   (harness-remote-parts "/ssh:u@box.example.invalid:")))
    (should (equal '("/ssh:u@box.example.invalid:" . "/var/log/")
                   (harness-remote-parts "/ssh:u@box.example.invalid:/var/log/")))
    ;; The jump hosts stay in the prefix, which `file-remote-p' leaves out.
    (should (equal '("/ssh:j|ssh:u@box#22:" . "~/x/") (harness-remote-parts "/ssh:j|ssh:u@box#22:~/x/")))
    (should (equal "/ssh:u@box#22:" (file-remote-p "/ssh:j|ssh:u@box#22:~/x/")))
    (should (equal '("/ssh:j1|ssh:u@j2#22|ssh:box:" . "/tmp") (harness-remote-parts "/ssh:j1|ssh:u@j2#22|ssh:box:/tmp")))
    (should (equal '("/ssh:[::1]#22:" . "~/x") (harness-remote-parts "/ssh:[::1]#22:~/x")))
    (should (equal '("/sudo:root@localhost:" . "~/x") (harness-remote-parts "/sudo:root@localhost:~/x")))
    ;; Another user's home and a quoted name are read as written too.
    (should (equal '("/ssh:box:" . "~bob/x") (harness-remote-parts "/ssh:box:~bob/x")))
    (should (equal '("/ssh:box:" . "/:~/x") (harness-remote-parts "/ssh:box:/:~/x")))
    ;; No TRAMP names: a local path, a relative one, nothing, an unfinished prefix.
    (dolist (name (list "/home/u/x" "x" "" nil 'symbol "/ssh:h" "/ssh:" "/tmp/archive.zip/inside"))
      (should-not (harness-remote-parts name)))
    (should (equal "/ssh:j|ssh:box:" (harness-remote-prefix "/ssh:j|ssh:box:~/a")))
    (should-not (harness-remote-prefix "/etc"))))

(ert-deftest harness-util-remote-home-names ()
  "A name is in a remote home directory when the local part of a TRAMP
name starts with a tilde: ~, ~/x and ~bob/x, but not a tilde further in,
a quoted one, or a local ~."
  (harness-test-without-connections
    (dolist (name '("/ssh:box:~" "/ssh:box:~/" "/ssh:box:~/x/y" "/ssh:box:~bob/x" "/ssh:j|ssh:box:~/x"
                    "/sudo:root@localhost:~/x" "/ssh:u@box.example.invalid:~/.ssh/config"))
      (should (harness-remote-home-p name)))
    (dolist (name '("/ssh:box:/x/~" "/ssh:box:/home/u" "/ssh:box:" "/ssh:box:/:~/x" "~/x" "~" "/home/u/~"
                    "x/~/y" "" nil 42))
      (should-not (harness-remote-home-p name)))
    (should (equal '("/ssh:box:" "~" "") (harness-remote-home-parts "/ssh:box:~")))
    (should (equal '("/ssh:box:" "~" "/") (harness-remote-home-parts "/ssh:box:~/")))
    (should (equal '("/ssh:box:" "~" "/x/y") (harness-remote-home-parts "/ssh:box:~/x/y")))
    (should (equal '("/ssh:box:" "~bob" "/x/y") (harness-remote-home-parts "/ssh:box:~bob/x/y")))
    (should (equal '("/ssh:j|ssh:box:" "~" "/a") (harness-remote-home-parts "/ssh:j|ssh:box:~/a")))
    (should-not (harness-remote-home-parts "/ssh:box:/etc"))
    (should-not (harness-remote-home-parts "~/x"))))

(ert-deftest harness-util-remote-home-tidy ()
  "The text of a name in a home directory is tidied without looking
anything up: `.', `..' and repeated slashes go, a trailing slash stays, the
home itself is ~/, and a `..' that leaves the home leaves nothing to
return, since only the host knows what lies above it."
  (harness-test-without-connections
    (dolist (case '(("~" . "~/") ("~/" . "~/") ("~/a" . "~/a") ("~/a/" . "~/a/")
                    ("~/a/./b//c/" . "~/a/b/c/") ("~/." . "~/") ("~/a/." . "~/a/")
                    ("~/a/.." . "~/") ("~/a/../b/" . "~/b/") ("~/a/b/../../c" . "~/c")
                    ("~bob/x/../y" . "~bob/y") ("~bob" . "~bob/")))
      (should (equal (cdr case) (harness-remote-home-tidy-local (car case))))
      (should (equal (and (cdr case) (concat "/ssh:j|ssh:box:" (cdr case)))
                     (harness-remote-home-tidy (concat "/ssh:j|ssh:box:" (car case))))))
    ;; Leaving the home: where it goes is the host's to say.
    (dolist (local '("~/.." "~/a/../.." "~/../x" "~bob/../.."))
      (should-not (harness-remote-home-tidy-local local))
      (should-not (harness-remote-home-tidy (concat "/ssh:box:" local))))
    ;; Not a name in a home directory.
    (should-not (harness-remote-home-tidy-local "/etc"))
    (should-not (harness-remote-home-tidy-local "x"))
    (should-not (harness-remote-home-tidy "/ssh:box:/etc"))
    (should-not (harness-remote-home-tidy "~/x"))
    (should-not (harness-remote-home-tidy nil))))

(ert-deftest harness-util-absolute-file-name-does-not-connect ()
  "A name in a remote home directory is only tidied, never expanded, against
any directory; every other name is `expand-file-name''s."
  (harness-test-without-connections
    (let ((home (concat "/ssh:u@box.example.invalid:")))
      (should (equal (concat home "~/b") (harness-absolute-file-name (concat home "~/a/../b"))))
      (should (equal (concat home "~/") (harness-absolute-file-name (concat home "~"))))
      (should (equal (concat home "~/b/") (harness-absolute-file-name (concat home "~/./b//") "/tmp/")))
      ;; A `..' out of the home stays as it was written.
      (should (equal (concat home "~/..") (harness-absolute-file-name (concat home "~/.."))))
      ;; Against a home directory: a relative name is put in it, an absolute one is not.
      (should (equal (concat home "~/d/foo") (harness-absolute-file-name "foo" (concat home "~/d/"))))
      (should (equal (concat home "~/foo") (harness-absolute-file-name "../foo" (concat home "~/d/"))))
      (should (equal (concat home "~/d/../../foo") (harness-absolute-file-name "../../foo" (concat home "~/d/"))))
      (should (equal "/etc/foo" (harness-absolute-file-name "/etc/foo" (concat home "~/d/"))))
      (should (equal "/ssh:other.example.invalid:/etc/x"
                     (harness-absolute-file-name "/ssh:other.example.invalid:/etc/foo/../x" (concat home "~/d/"))))
      ;; Everything else is as `expand-file-name' has it, a TRAMP name with an absolute local part too.
      (should (equal "/tmp/x/a/b" (harness-absolute-file-name "a/b" "/tmp/x/")))
      (should (equal "/tmp/b" (harness-absolute-file-name "../b" "/tmp/x/")))
      (should (equal (expand-file-name "~/b") (harness-absolute-file-name "~/b" "/tmp/x/")))
      (should (equal (concat home "/var/x") (harness-absolute-file-name (concat home "/var/log/../x") "/")))
      (should (equal (concat home "/foo") (harness-absolute-file-name "foo" (concat home "/")))))))

(ert-deftest harness-util-abbreviate-file-name-does-not-connect ()
  "A message names a path as `abbreviate-file-name' does, except that a remote
name is left as it is written: abbreviating one in a home directory asks
the host where its home is, and any other asks it, once TRAMP is connected
to it, whether its file system is case sensitive."
  (harness-test-without-connections
    (dolist (name '("/ssh:u@box.example.invalid:~/x" "/ssh:u@box.example.invalid:~/" "/ssh:box.example.invalid:~bob/x"
                    "/ssh:u@box.example.invalid:/var/log/x" "/ssh:u@box.example.invalid:/var/log/../x"
                    "/ssh:j|ssh:box.example.invalid:/" "/ssh:box.example.invalid:"))
      (should (equal name (harness-abbreviate-file-name name))))
    (dolist (name (list "/tmp/x" "/" "relative/x"
                        (expand-file-name "~/foo/bar") (expand-file-name "~") (concat (expand-file-name "~") "/")))
      (should (equal (abbreviate-file-name name) (harness-abbreviate-file-name name))))))

(ert-deftest harness-util-file-remote-p-reads-a-home-name-as-written ()
  "For a name in a remote home directory `harness-file-remote-p' says what
`file-remote-p' says of a host nothing is connected to: the host, and
with `localname' the local part as written.  Any other name it leaves
to `file-remote-p'."
  (harness-test-without-connections
    (let ((name "/ssh:admin@box.example.invalid#22:~/x"))
      (should (equal "/ssh:admin@box.example.invalid#22:" (harness-file-remote-p name)))
      (should (equal "~/x" (harness-file-remote-p name 'localname)))
      (should (equal "admin" (harness-file-remote-p name 'user)))
      (should (equal "box.example.invalid#22" (harness-file-remote-p name 'host)))
      (should (equal "ssh" (harness-file-remote-p name 'method)))
      ;; Connected: to nothing, as no connection is open.
      (should-not (harness-file-remote-p name nil t))
      (should-not (harness-file-remote-p name 'localname t)))
    (should (equal "/ssh:box.example.invalid:" (harness-file-remote-p "/ssh:j|ssh:box.example.invalid:~/x")))
    (dolist (name '("/ssh:box.example.invalid:/etc/x" "/etc/x" "x" "/ssh:box.example.invalid:"))
      (dolist (id '(nil localname host user method))
        (should (equal (file-remote-p name id) (harness-file-remote-p name id)))))))

(ert-deftest harness-util-remote-parent-dir ()
  "The directory above a remote directory is the next one up its path; above
a home directory it is the root of the host, and the root has none."
  (harness-test-without-connections
    (should (equal "/ssh:box:~/a/" (harness-remote-parent-dir "/ssh:box:~/a/b/")))
    (should (equal "/ssh:box:~/" (harness-remote-parent-dir "/ssh:box:~/a/")))
    (should (equal "/ssh:box:~/a/" (harness-remote-parent-dir "/ssh:box:~/a/b")))
    (should (equal "/ssh:box:/" (harness-remote-parent-dir "/ssh:box:~/")))
    (should (equal "/ssh:box:/" (harness-remote-parent-dir "/ssh:box:~")))
    (should (equal "/ssh:box:/" (harness-remote-parent-dir "/ssh:box:~bob/")))
    (should (equal "/ssh:box:/var/" (harness-remote-parent-dir "/ssh:box:/var/log/")))
    (should (equal "/ssh:box:/" (harness-remote-parent-dir "/ssh:box:/var/")))
    (should (equal "/ssh:box:/" (harness-remote-parent-dir "/ssh:box:/a")))
    (should-not (harness-remote-parent-dir "/ssh:box:/"))
    (should-not (harness-remote-parent-dir "/ssh:box:"))
    ;; Jump hosts are kept.
    (should (equal "/ssh:j|ssh:box:~/a/" (harness-remote-parent-dir "/ssh:j|ssh:box:~/a/b/")))
    (should (equal "/ssh:j|ssh:box:/" (harness-remote-parent-dir "/ssh:j|ssh:box:~/")))
    (should-not (harness-remote-parent-dir "/ssh:j|ssh:box:/"))
    ;; A local name has no host to hold it.
    (should-not (harness-remote-parent-dir "/var/log/"))
    (should-not (harness-remote-parent-dir "relative/"))))

(ert-deftest harness-util-image-pixel-size ()
  "An image's size is read from its header, for every raster format
ask_user takes; an SVG, a format it does not know and a missing file
have none."
  (let ((u16le (lambda (n) (list (logand n 255) (ash n -8))))
        (u16be (lambda (n) (list (ash n -8) (logand n 255))))
        (u24le (lambda (n) (list (logand n 255) (logand (ash n -8) 255) (ash n -16))))
        (u32le (lambda (n) (list (logand n 255) (logand (ash n -8) 255) (logand (ash n -16) 255) (logand (ash n -24) 255)))))
    (cl-flet ((size (&rest parts)
                (harness-image-pixel-size
                 nil (apply #'harness-core-test--bytes
                            (apply #'append (mapcar (lambda (p) (if (listp p) p (list p))) parts))))))
      (should (equal '(2 . 2) (harness-image-pixel-size nil harness-test-png)))
      (should (equal '(1400 . 12000)
                     (size "\211PNG\r\n\032\n" "\0\0\0\rIHDR" 0 0 5 120 0 0 46 224 8 6 0 0 0)))
      (should (equal '(320 . 200) (size "GIF89a" (funcall u16le 320) (funcall u16le 200) 0 0 0)))
      ;; JPEG: the frame header comes after other segments.
      (should (equal '(640 . 480)
                     (size 255 216 255 224 (funcall u16be 16) (make-list 14 0)
                           255 225 (funcall u16be 300) (make-list 298 7)
                           255 192 (funcall u16be 17) 8 (funcall u16be 480) (funcall u16be 640) 3 (make-list 12 0))))
      (should (equal '(800 . 600)
                     (size "RIFF" 0 0 0 0 "WEBPVP8 " 0 0 0 0 0 0 0 157 1 42
                           (funcall u16le 800) (funcall u16le 600) 0 0)))
      (should (equal '(100 . 50) (size "RIFF" 0 0 0 0 "WEBPVP8L" 0 0 0 0 47 #x63 #x40 #x0c 0 0 0)))
      (should (equal '(4000 . 3000)
                     (size "RIFF" 0 0 0 0 "WEBPVP8X" 0 0 0 0 0 0 0 0
                           (funcall u24le 3999) (funcall u24le 2999) 0 0)))
      ;; BMP, its height below zero for a top-down image.
      (should (equal '(300 . 200)
                     (size "BM" (make-list 12 0) (funcall u32le 40) (funcall u32le 300)
                           (funcall u32le (- #x100000000 200)) 0 0)))
      (should-not (size "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 600 400\"/>"))
      (should-not (size "not an image at all"))
      (should-not (size ""))))
  (let ((file (make-temp-file "harness-util-test-" nil ".png"))
        (jpeg (make-temp-file "harness-util-test-" nil ".jpg"))
        (coding-system-for-write 'no-conversion))
    (unwind-protect
        (progn
          (write-region harness-test-png nil file nil 'silent)
          (should (equal '(2 . 2) (harness-image-pixel-size file)))
          ;; A JPEG whose size comes after more than the first read:
          ;; two long segments of metadata before it.
          (write-region (concat (unibyte-string 255 216 255 225 255 0) (make-string 65278 7 nil)
                                (unibyte-string 255 226 255 0) (make-string 65278 7 nil)
                                (unibyte-string 255 192 0 17 8 1 224 2 128 3) (make-string 12 0 nil))
                        nil jpeg nil 'silent)
          (should (> (file-attribute-size (file-attributes jpeg)) 65536))
          (should (equal '(640 . 480) (harness-image-pixel-size jpeg))))
      (delete-file file)
      (delete-file jpeg))
    (should-not (harness-image-pixel-size file))))

(ert-deftest harness-util-senders ()
  "Who sent a message reads the same before and after JSON (kind a string)."
  (let* ((system (harness-sender-system "tasks"))
         (session (harness-sender-session '(:id "s1" :name "Fix the parser" :model "x")))
         (parsed (harness-json-parse (harness-json-encode system))))
    (should (equal '(:kind system :source "tasks") system))
    (should (equal '(:kind session :id "s1" :name "Fix the parser") session))
    (should (equal '(:kind "system" :source "tasks") parsed))
    (should (eq 'system (harness-sender-kind parsed)))
    (should (eq 'session (harness-sender-kind session)))
    ;; The user: no sender, or nothing that names a kind.
    (dolist (none '(nil (:source "x") (:kind nil) (:kind "") (:kind :false)))
      (should-not (harness-sender-kind none)))
    (should (equal parsed (harness-node-sender (list :kind 'user :meta (list :steering t :from parsed)))))
    (should-not (harness-node-sender '(:kind user :meta (:steering t))))
    (should-not (harness-node-sender '(:kind user :meta (:from (:source "x")))))
    (should (equal "the harness (tasks)" (harness-sender-description parsed)))
    (should (equal "the harness" (harness-sender-description '(:kind system))))
    (should (equal "session s1 \"Fix the parser\"" (harness-sender-description session)))
    (should (equal "session s2" (harness-sender-description '(:kind "session" :id "s2"))))
    (should (equal "the user" (harness-sender-description nil)))))

(ert-deftest harness-util-session-waiting-on-user ()
  "A session waits for the user when a request is pending on it, or it is blocked.
The server holds a session's status as a symbol and its pending requests
as a list; a UI holds what came over JSON, a string and perhaps a
vector.  They read the same, and a session with neither is not waiting.
The question a cold prompt cache asks is a pending request like any
other."
  (let ((question (list :id "p1" :kind 'question
                        :payload (list :question "Carry on with the cold cache?"))))
    ;; The server's view.
    (should (harness-session-waiting-on-user-p (list :status 'blocked :pending (list question))))
    (should (harness-session-waiting-on-user-p (list :status 'running :pending (list question))))
    (should (harness-session-waiting-on-user-p (list :status 'blocked)))
    (dolist (status '(idle running inactive))
      (should-not (harness-session-waiting-on-user-p (list :status status)))
      (should-not (harness-session-waiting-on-user-p (list :status status :pending nil))))
    ;; The UI's, over JSON.
    (should (harness-session-waiting-on-user-p (list :status "blocked" :pending (vector question))))
    (should (harness-session-waiting-on-user-p (list :status "running" :pending (vector question))))
    (should (harness-session-waiting-on-user-p (list :status "blocked" :pending [])))
    (should-not (harness-session-waiting-on-user-p (list :status "running" :pending [])))
    (should-not (harness-session-waiting-on-user-p (list :status "idle")))
    ;; No session, no answer to wait for.
    (should-not (harness-session-waiting-on-user-p nil))
    (should (eq t (harness-session-waiting-on-user-p (list :status 'blocked))))))

(ert-deftest harness-util-node-fold ()
  "A hint that folds several lines under a title reads the same after JSON.
Items without text, and a fold with no title or no item, are no fold."
  (let* ((fold (list :key "k" :title "Several things"
                     :items (list (list :ts 1760000000.5 :text "one")
                                  (list :ts 1760000100.25 :text "two"))))
         (node (list :kind 'hint :content "Several things\none\ntwo" :meta (list :fold fold)))
         (parsed (list :kind "hint" :meta (harness-json-parse
                                           (harness-json-encode (list :fold fold))))))
    (should (equal fold (harness-node-fold node)))
    ;; What travelled over JSON reads as what did not.
    (should (equal fold (harness-node-fold parsed)))
    ;; Another key of the meta, and another kind of hint, are no fold.
    (should-not (harness-node-fold '(:kind hint :content "plain")))
    (should-not (harness-node-fold '(:kind hint :meta (:permission (:scope session)))))
    ;; An item with no text is left out, one with no time keeps its text,
    ;; and a time that is no number is none.
    (should (equal '(:key nil :title "T" :items ((:ts nil :text "kept") (:ts nil :text "x")))
                   (harness-node-fold
                    '(:meta (:fold (:title "T"
                                    :items ((:text "kept") (:ts 1) (:text "") "stray" nil
                                            (:ts "late" :text "x"))))))))
    ;; No title, an empty one, or no item left: no fold.
    (should-not (harness-node-fold '(:meta (:fold (:items ((:text "a")))))))
    (should-not (harness-node-fold '(:meta (:fold (:title "" :items ((:text "a")))))))
    (should-not (harness-node-fold '(:meta (:fold (:title "T" :items ((:ts 1)))))))
    (should-not (harness-node-fold '(:meta (:fold (:title "T")))))
    (should-not (harness-node-fold '(:meta (:fold (:title "T" :items "text")))))
    (should-not (harness-node-fold '(:meta (:fold "T"))))
    ;; A client may send the items as a vector.
    (should (equal '((:ts nil :text "a"))
                   (plist-get (harness-node-fold '(:meta (:fold (:title "T" :items [(:text "a")]))))
                              :items)))))

(ert-deftest harness-thinking-level-fit-fits-a-level-to-a-model ()
  "A thinking level is fitted to the levels a model offers, by their order.
The level itself when the model has it; else the strongest it has below
it; else, every one being stronger, its weakest.  A level the order
does not know ranks after every one it does.  Nothing to fit is nil.
It is the one rule a BTW's level, Copilot's effort and Bedrock's effort
are fitted by."
  (let ((ladder '("low" "medium" "high" "xhigh" "max"))
        (deep '("low" "high" "max")))
    ;; The order is weakest first, and the rank follows it.
    (should (equal '("none" "minimal" "low" "medium" "high" "xhigh" "max") harness-thinking-level-order))
    (should (equal '(0 1 2 3 4 5 6) (mapcar #'harness-thinking-level-rank harness-thinking-level-order)))
    (should (> (harness-thinking-level-rank "ultra") (harness-thinking-level-rank "max")))
    ;; The level itself, wherever it stands among the others.
    (dolist (level ladder)
      (should (equal level (harness-thinking-level-fit level ladder))))
    (should (equal "medium" (harness-thinking-level-fit "medium" '("max" "medium" "low"))))
    ;; Else the strongest below it, the order of the list no matter.
    (should (equal "low" (harness-thinking-level-fit "medium" deep)))
    (should (equal "low" (harness-thinking-level-fit "medium" (reverse deep))))
    (should (equal "high" (harness-thinking-level-fit "xhigh" deep)))
    (should (equal "medium" (harness-thinking-level-fit "xhigh" '("max" "low" "medium"))))
    (should (equal "minimal" (harness-thinking-level-fit "low" '("high" "minimal" "none"))))
    (should (equal "none" (harness-thinking-level-fit "minimal" '("none" "high"))))
    ;; Else the weakest, everything it has being stronger.
    (should (equal "high" (harness-thinking-level-fit "low" '("high" "max"))))
    (should (equal "high" (harness-thinking-level-fit "medium" '("max" "high"))))
    (should (equal "max" (harness-thinking-level-fit "low" '("max"))))
    ;; A level the order does not know ranks after all it does: it is the
    ;; strongest asked for, and the strongest a model can offer.
    (should (equal "max" (harness-thinking-level-fit "ultra" ladder)))
    (should (equal "ultra" (harness-thinking-level-fit "ultra" '("low" "ultra"))))
    (should (equal "low" (harness-thinking-level-fit "max" '("low" "ultra"))))
    (should (equal "ultra" (harness-thinking-level-fit "low" '("ultra" "turbo"))))
    ;; Nothing to fit: no string, or no level to fit to.
    (should-not (harness-thinking-level-fit nil ladder))
    (should-not (harness-thinking-level-fit 'low ladder))
    (should-not (harness-thinking-level-fit :false ladder))
    (should-not (harness-thinking-level-fit "low" nil))
    (should-not (harness-thinking-level-fit "low" '(nil low)))
    (should (equal "low" (harness-thinking-level-fit "medium" '(nil "low" high))))
    ;; The list it is given is left as it was.
    (let ((levels (list "max" "low" "high")))
      (should (equal "low" (harness-thinking-level-fit "medium" levels)))
      (should (equal '("max" "low" "high") levels)))))

(ert-deftest harness-http-sse-parser ()
  (let (events)
    (let ((f (harness-http-sse-parser (lambda (ev data) (push (cons ev data) events)))))
      (funcall f "event: ping\ndata: {\"a\":1}\n\n: comment\ndata: line1\ndata: li")
      (funcall f "ne2\n\n"))
    (should (equal '(("ping" . "{\"a\":1}") (nil . "line1\nline2")) (reverse events)))))

(ert-deftest harness-loader-start-and-reload-with-temp-module ()
  (harness-test-reset-bus)
  (let* ((dir (harness-test-temp-dir))
         (moddir (expand-file-name "lisp/modules" dir))
         (file (expand-file-name "harness-demo.el" moddir)))
    (make-directory moddir t)
    (with-temp-file file
      (insert ";;; -*- lexical-binding: t -*-\n(harness-define-module 'demo :init (lambda () (harness-register-method 'demo/ping (lambda () 'pong))))\n(provide 'harness-demo)\n"))
    (cl-letf (((symbol-function 'harness--path)
               (lambda (rel) (expand-file-name rel dir))))
      (let ((harness-module-directories '("lisp/modules"))
            (harness--core-files nil)
            (harness--library-files nil)
            (harness-process nil)
            (harness-enabled-modules t)
            (harness-disabled-modules nil))
        (should (harness-start))
        (should (eq 'pong (harness-call 'demo/ping)))
        (should (harness-module-ready-p 'demo))
        ;; A broken edit is refused and leaves the old definitions intact.
        (with-temp-file file (insert "(harness-define-module 'demo :init (lambda () (oops"))
        (should-not (harness-reload))
        (should (eq 'pong (harness-call 'demo/ping)))
        ;; A good edit is picked up.
        (with-temp-file file
          (insert ";;; -*- lexical-binding: t -*-\n(harness-define-module 'demo :init #'ignore)\n(harness-register-method 'demo/ping (lambda () 'pong2))\n(provide 'harness-demo)\n"))
        (should (harness-reload))
        (should (eq 'pong2 (harness-call 'demo/ping)))))
    (delete-directory dir t)))

(defvar harness-core-test--reload-hook nil
  "A hook the test module of `harness-loader-reload-wires-in-what-init-adds' adds to.")

(defvar harness-core-test--first-starts 0
  "How often that module did the work it does once per start.")

(ert-deftest harness-loader-reload-wires-in-what-init-adds ()
  "`harness-reload' runs a ready module's INIT again, so what new code adds there works.
A second reload adds nothing twice, the work an INIT does once per start
is not done again, and an INIT that fails now is reported by the reload
while the module stays ready with what it set up before."
  (harness-test-reset-bus)
  (let* ((dir (harness-test-temp-dir))
         (file (expand-file-name "lisp/modules/harness-demo.el" dir))
         (write (lambda (&rest init)
                  (harness-core-test--write-elisp
                   file
                   `(defun harness-demo--init ()
                      (unless (harness-module-ready-p 'demo)
                        (setq harness-core-test--first-starts (1+ harness-core-test--first-starts)))
                      ,@init)
                   '(harness-define-module 'demo :init #'harness-demo--init)
                   '(provide 'harness-demo)))))
    (setq harness-core-test--reload-hook nil
          harness-core-test--first-starts 0)
    (funcall write '(add-hook 'harness-core-test--reload-hook #'harness-core-test--a))
    ;; Each reload loads harness.el first: the real one would put back
    ;; the `harness--path' that this test replaces.
    (harness-core-test--write-elisp (expand-file-name "harness.el" dir) '(ignore))
    (unwind-protect
        (cl-letf (((symbol-function 'harness--path)
                   (lambda (rel) (expand-file-name rel dir))))
          (let ((harness--self-file (expand-file-name "harness.el" dir))
                (harness-module-directories '("lisp/modules"))
                (harness--core-files nil)
                (harness--library-files nil)
                (harness-process nil)
                (harness-enabled-modules t)
                (harness-disabled-modules nil))
            (should (harness-start))
            (should (equal '(harness-core-test--a) harness-core-test--reload-hook))
            ;; New code adds a hook in INIT: the reload adds it.
            (funcall write
                     '(add-hook 'harness-core-test--reload-hook #'harness-core-test--a)
                     '(add-hook 'harness-core-test--reload-hook #'harness-core-test--b))
            (should (harness-reload))
            (should (equal '(harness-core-test--b harness-core-test--a) harness-core-test--reload-hook))
            ;; Another reload adds nothing twice, and starts nothing again.
            (should (harness-reload))
            (should (= 2 (length harness-core-test--reload-hook)))
            (should (= 1 harness-core-test--first-starts))
            ;; An INIT that fails now is reported; the module stays ready.
            (funcall write '(error "Init broke"))
            (let ((errors (plist-get (harness--reload) :errors)))
              (should (= 1 (length errors)))
              (should (string-match-p "module demo: Init broke" (car errors))))
            (should (harness-module-ready-p 'demo))
            (should (= 2 (length harness-core-test--reload-hook)))
            (harness-stop)))
      (fmakunbound 'harness-demo--init)
      (setq features (delq 'harness-demo features))
      (delete-directory dir t))))

(ert-deftest harness-loader-reloads-library-files ()
  "Library files load compiled at start and again at every reload.
A module reloaded after an update must find the libraries it requires
as they are now, not as this Emacs first loaded them, and a library
that does not compile refuses the reload like a module does."
  (harness-test-reset-bus)
  (let* ((dir (harness-test-temp-dir))
         (lib (expand-file-name "lisp/harness-testlib.el" dir))
         (moddir (expand-file-name "lisp/modules" dir))
         (version (lambda (n)
                    (with-temp-file lib
                      (insert (format ";;; -*- lexical-binding: t -*-\n(defun harness-testlib-answer () %d)\n(provide 'harness-testlib)\n" n))))))
    (make-directory moddir t)
    (funcall version 1)
    (with-temp-file (expand-file-name "harness-libuser.el" moddir)
      (insert ";;; -*- lexical-binding: t -*-\n(require 'harness-testlib)\n(harness-define-module 'libuser)\n"
              "(harness-register-method 'libuser/answer (lambda () (harness-testlib-answer)))\n(provide 'harness-libuser)\n"))
    (unwind-protect
        (cl-letf (((symbol-function 'harness--path)
                   (lambda (rel) (expand-file-name rel dir))))
          (let ((harness-module-directories '("lisp/modules"))
                (harness--core-files nil)
                (harness--library-files '("lisp/harness-testlib.el"))
                (harness-process nil)
                (harness-enabled-modules t)
                (harness-disabled-modules nil))
            (should (harness-start))
            (should (equal 1 (harness-call 'libuser/answer)))
            (should (funcall (if (fboundp 'compiled-function-p) #'compiled-function-p #'byte-code-function-p)
                             (symbol-function 'harness-testlib-answer)))
            ;; Broken, it refuses the reload and the old definitions stay.
            (with-temp-file lib (insert "(defun harness-testlib-answer () (oops"))
            (should-not (harness-reload))
            (should (equal 1 (harness-call 'libuser/answer)))
            ;; Updated, the reload loads it again.
            (funcall version 2)
            (should (harness-reload))
            (should (equal 2 (harness-call 'libuser/answer)))))
      (makunbound 'harness-testlib-answer)
      (fmakunbound 'harness-testlib-answer)
      (setq features (delq 'harness-testlib features))
      (delete-directory dir t))))

;;;; A reload unbinds what a file no longer defines

(defmacro harness-core-test-with-reload-tree (&rest body)
  "Run BODY in a tree of module files it writes, to start the harness from and reload.
`tree' is the tree.  `write' is a function of a module's short name and
the forms of its file: it writes lisp/modules/harness-reloadtest-NAME.el,
which loads in the order of the names.  The harness's own harness.el is
left out of the reloads, a file of the tree's own standing in for it: the
real one would put back the `harness--path' this replaces.  What the
files define is named harness-reloadtest-..., and is gone after BODY, with
the `load-history' entries of the state directory they were compiled in."
  (declare (indent 0))
  `(let ((tree (harness-test-temp-dir)))
     (harness-test-reset-bus)
     (harness-core-test--write-elisp (expand-file-name "harness.el" tree) '(ignore))
     (unwind-protect
         (harness-test-with-temp-state
           (unwind-protect
               (cl-letf (((symbol-function 'harness--path)
                          (lambda (rel) (expand-file-name rel tree))))
                 (let ((write (lambda (name &rest forms)
                                (apply #'harness-core-test--write-elisp
                                       (expand-file-name
                                        (format "lisp/modules/harness-reloadtest-%s.el" name) tree)
                                       forms)))
                       (harness--self-file (expand-file-name "harness.el" tree))
                       (harness-module-directories '("lisp/modules"))
                       (harness--core-files nil)
                       (harness--library-files nil)
                       (harness-process nil)
                       (harness-enabled-modules t)
                       (harness-disabled-modules nil))
                   (ignore write)
                   ,@body))
             (mapatoms (lambda (symbol)
                         (when (string-prefix-p "harness-reloadtest-" (symbol-name symbol))
                           (fmakunbound symbol))))
             (setq features (cl-remove-if (lambda (feature)
                                            (string-prefix-p "harness-reloadtest-" (symbol-name feature)))
                                          features)
                   load-history (cl-remove-if (lambda (entry)
                                                (and (stringp (car entry))
                                                     (or (string-prefix-p harness-state-directory (car entry))
                                                         (string-prefix-p tree (car entry)))))
                                              load-history))))
       (harness-test-reset-bus)
       (delete-directory tree t))))

(ert-deftest harness-loader-reload-premise-a-leftover-reads-its-documentation-by-loading ()
  "The premise of the unbinding: a function left defined costs a load per read.
A file loaded again without one of its commands leaves it defined, with
the documentation pointer of the .elc the load rewrote, and the new .elc
never has it: Emacs loads the library again each time it is asked for
that documentation.  A command the new file has reads its own."
  (harness-core-test-with-reload-tree
    (let ((file (expand-file-name "lisp/modules/harness-reloadtest-a.el" tree))
          (loads nil))
      (funcall write "a"
               '(defun harness-reloadtest-kept () "Kept, version 1." (interactive) 1)
               '(defun harness-reloadtest-left () "Left." (interactive) 2))
      (harness-load-compiled file)
      (funcall write "a"
               '(defun harness-reloadtest-kept () "Kept, version 2, longer than before." (interactive) 1))
      (harness-load-compiled file)
      (should (fboundp 'harness-reloadtest-left))
      (let ((after-load-functions (list (lambda (loaded) (push loaded loads)))))
        (documentation 'harness-reloadtest-kept)
        (should-not loads)
        (documentation 'harness-reloadtest-left)
        (documentation 'harness-reloadtest-left)
        (should (= 2 (length loads)))))))

(ert-deftest harness-loader-reload-unbinds-what-a-file-no-longer-defines ()
  "A reload unbinds the functions a file stopped defining, and only those.
The file is rewritten without a command, a macro and an alias.  A
function left defined keeps the documentation pointer of the .elc the
reload rewrote, and Emacs would load the library again for each
`documentation' asked of it, as it does for the quick search's scan of
the commands.  What the file still defines is not touched, and its
documentation loads nothing.  A key that a kept keymap binds to a removed
command reports it undefined."
  (harness-core-test-with-reload-tree
    (let ((loads nil)
          (keymap (make-sparse-keymap)))
      (funcall write "a"
               '(defun harness-reloadtest-kept () "Kept, version 1." (interactive) 1)
               '(defun harness-reloadtest-removed () "Removed." (interactive) 2)
               '(defmacro harness-reloadtest-macro () 3)
               '(defalias 'harness-reloadtest-alias #'harness-reloadtest-kept))
      (should (harness-start))
      (define-key keymap "r" #'harness-reloadtest-removed)
      (should (commandp 'harness-reloadtest-removed))
      (should (equal "Removed." (documentation 'harness-reloadtest-removed)))
      ;; The file, without them; its documentation moves in the .elc.
      (funcall write "a"
               '(defun harness-reloadtest-kept ()
                  "Kept, version 2, with a longer text to move what follows." (interactive) 1))
      (let ((result (harness--reload)))
        (should-not (plist-get result :errors))
        (should (equal '(harness-reloadtest-alias harness-reloadtest-macro harness-reloadtest-removed)
                       (plist-get result :unbound))))
      (should-not (fboundp 'harness-reloadtest-removed))
      (should-not (fboundp 'harness-reloadtest-macro))
      (should-not (fboundp 'harness-reloadtest-alias))
      (should (commandp 'harness-reloadtest-kept))
      (should (string-search "unbound 3 functions that harness-reloadtest-a no longer defines: harness-reloadtest-alias, harness-reloadtest-macro, harness-reloadtest-removed"
                             (harness-core-test--log-text)))
      ;; Reading what is kept loads no library again.
      (let ((after-load-functions (list (lambda (file) (push file loads)))))
        (should (equal "Kept, version 2, with a longer text to move what follows."
                       (documentation 'harness-reloadtest-kept)))
        (should-not loads))
      ;; The keymap still binds the command, which is none now.
      (should (eq 'harness-reloadtest-removed (lookup-key keymap "r")))
      (should-not (commandp (lookup-key keymap "r")))
      ;; Reloaded again with nothing more to unbind, nothing is.
      (should-not (plist-get (harness--reload) :unbound))
      (should (commandp 'harness-reloadtest-kept)))))

(ert-deftest harness-loader-reload-unbinds-what-a-file-dropped-though-a-stale-copy-lists-it ()
  "The copy a `require' loaded before the loader did is no file defining the function.
A module another requires loads from `load-path', as source, before the
loader reaches it and loads its compiled copy over it.  The entry of
that source stays in `load-history' with what the file defined at the
start, so a function the file drops later is still listed by a file --
its own, older one.  In a session that is most of the big modules (the
task board's and the chat's among them) and the libraries."
  (harness-core-test-with-reload-tree
    (let ((file (expand-file-name "lisp/modules/harness-reloadtest-a.el" tree)))
      (funcall write "a"
               '(defun harness-reloadtest-kept () 1)
               '(defun harness-reloadtest-removed () 2))
      (load file nil t)
      (should (harness-start))
      (should (cl-every (lambda (f) (member f (harness-core-test--listed-in-entries-named "harness-reloadtest-a")))
                        '(harness-reloadtest-kept harness-reloadtest-removed)))
      (funcall write "a" '(defun harness-reloadtest-kept () 1))
      (should (equal '(harness-reloadtest-removed) (plist-get (harness--reload) :unbound)))
      (should-not (fboundp 'harness-reloadtest-removed))
      (should (fboundp 'harness-reloadtest-kept))
      ;; The stale copy still lists it, and the next reload leaves things be.
      (should (member 'harness-reloadtest-removed
                      (harness-core-test--listed-in-entries-named "harness-reloadtest-a")))
      (should-not (plist-get (harness--reload) :unbound)))))

(ert-deftest harness-loader-reload-logs-a-dozen-names-of-what-it-unbound ()
  "The log line names twelve of what a library lost, and how many more.
A file that loses many functions at once -- a prefix renamed -- would
otherwise log a line of kilobytes.  The result lists them all."
  (harness-core-test-with-reload-tree
    (let ((names (cl-loop for n from 1 to 14
                          collect (intern (format "harness-reloadtest-f%02d" n)))))
      (apply write "a" (mapcar (lambda (name) `(defun ,name () 1)) names))
      (should (harness-start))
      (funcall write "a")
      (should (equal names (plist-get (harness--reload) :unbound)))
      (should (string-search
               (concat "unbound 14 functions that harness-reloadtest-a no longer defines: "
                       (mapconcat #'symbol-name (cl-subseq names 0 12) ", ")
                       " and 2 more\n")
               (harness-core-test--log-text)))
      (should-not (string-search "harness-reloadtest-f13," (harness-core-test--log-text))))))

(ert-deftest harness-loader-reload-unbinds-what-harness-el-no-longer-defines ()
  "harness.el is a library like the others: what it stopped defining goes."
  (harness-core-test-with-reload-tree
    (let ((self (expand-file-name "harness.el" tree)))
      (harness-core-test--write-elisp self
                                      '(defun harness-reloadtest-self-kept () 1)
                                      '(defun harness-reloadtest-self-removed () 2))
      (load self nil t)
      (should (harness-start))
      (harness-core-test--write-elisp self '(defun harness-reloadtest-self-kept () 1))
      (should (equal '(harness-reloadtest-self-removed) (plist-get (harness--reload) :unbound)))
      (should (fboundp 'harness-reloadtest-self-kept))
      (should-not (fboundp 'harness-reloadtest-self-removed)))))

(ert-deftest harness-loader-reload-keeps-a-function-moved-to-another-file ()
  "A function that left one file for another reloaded with it stays defined.
Whether the file that took it loads after the one that gave it up, or
before: the check waits until every file has loaded."
  (harness-core-test-with-reload-tree
    (funcall write "a"
             '(defun harness-reloadtest-a-only () 'a)
             '(defun harness-reloadtest-late () 'a))
    (funcall write "b"
             '(defun harness-reloadtest-b-only () 'b)
             '(defun harness-reloadtest-early () 'b))
    (should (harness-start))
    ;; Late moves from a to b, which loads after it; early from b to a.
    (funcall write "a"
             '(defun harness-reloadtest-a-only () 'a)
             '(defun harness-reloadtest-early () 'a))
    (funcall write "b"
             '(defun harness-reloadtest-b-only () 'b)
             '(defun harness-reloadtest-late () 'b))
    (let ((result (harness--reload)))
      (should-not (plist-get result :errors))
      (should-not (plist-get result :unbound)))
    (should (eq 'b (harness-reloadtest-late)))
    (should (eq 'a (harness-reloadtest-early)))
    (should (eq 'a (harness-reloadtest-a-only)))
    (should (eq 'b (harness-reloadtest-b-only)))))

(ert-deftest harness-loader-reload-keeps-a-function-redefined-since-the-snapshot ()
  "A function not the one a library defined, any more, stays defined.
The snapshot holds what each function was before the files loaded; one
that something replaced while they did -- here the new file, which sets
it without a `defun' -- is not what the library defined."
  (harness-core-test-with-reload-tree
    (funcall write "a"
             '(defun harness-reloadtest-replaced () 'defined)
             '(defun harness-reloadtest-removed () 'defined))
    (should (harness-start))
    (funcall write "a" '(fset 'harness-reloadtest-replaced (lambda () 'by-hand)))
    (let ((result (harness--reload)))
      (should-not (plist-get result :errors))
      (should (equal '(harness-reloadtest-removed) (plist-get result :unbound))))
    (should (eq 'by-hand (harness-reloadtest-replaced)))
    (should-not (fboundp 'harness-reloadtest-removed))))

(ert-deftest harness-loader-reload-keeps-a-function-another-file-defines ()
  "A function that a file outside the reload also defines stays defined.
The file that dropped it was not the only one to define it -- a generic
that another file declares is one such.  The function is still the very
one the library defined, since nothing loaded it again, so only
`symbol-file' tells."
  (harness-core-test-with-reload-tree
    (let ((shared (expand-file-name "shared.el" tree)))
      (funcall write "a" '(defun harness-reloadtest-shared () 'a))
      (should (harness-start))
      (harness-core-test--write-elisp shared '(defun harness-reloadtest-shared () 'shared))
      (load shared nil t)
      (funcall write "a" '(defun harness-reloadtest-here () 'a))
      (let ((result (harness--reload)))
        (should-not (plist-get result :errors))
        (should-not (plist-get result :unbound)))
      (should (eq 'shared (harness-reloadtest-shared))))))

(defun harness-core-test--listed-in-entries-named (name)
  "Return the functions the `load-history' entries of the files named NAME record as defined.
Whichever directory they were loaded from, source or compiled."
  (cl-loop for entry in load-history
           when (and (stringp (car entry)) (equal (file-name-base (car entry)) name))
           append (cl-loop for element in (cdr entry)
                           when (eq (car-safe element) 'defun) collect (cdr element))))

(defun harness-core-test--defined-in (name)
  "Return the functions the entry of test module NAME in `load-history' records, sorted.
They are its `(defun . F)' elements, which `defalias' and `defmacro' make
too (see `harness-core-test-with-reload-tree')."
  (let ((file (harness--compiled-name (format "harness-reloadtest-%s.el" name))))
    (sort (cl-loop for element in (cdr (assoc file load-history))
                   when (eq (car-safe element) 'defun) collect (cdr element))
          #'string<)))

(ert-deftest harness-loader-reload-keeps-a-generic-function ()
  "A generic function is not one a file dropped, whoever made it.
The first `cl-defmethod' of a generic that has no `cl-defgeneric' records
`(defun . F)' in the entry of its file at the first load only: the next
load does not, with the generic still there and no other file defining
it.  Until a call has made Emacs replace the function by the one the
methods dispatch through, it is the very function the snapshot holds.
One a file declares with `cl-defgeneric' and then drops has methods that
may be in any file: it is left alone."
  (harness-core-test-with-reload-tree
    (funcall write "a"
             '(cl-defmethod harness-reloadtest-made ((x integer)) (list 'integer x))
             '(cl-defgeneric harness-reloadtest-declared (x) "Declared.")
             '(cl-defmethod harness-reloadtest-declared ((x string)) (list 'string x)))
    (should (harness-start))
    (should (equal '(harness-reloadtest-declared harness-reloadtest-made)
                   (harness-core-test--defined-in "a")))
    (let ((result (harness--reload)))
      (should-not (plist-get result :errors))
      (should-not (plist-get result :unbound)))
    ;; The entry has forgotten the one that a method made.
    (should (equal '(harness-reloadtest-declared) (harness-core-test--defined-in "a")))
    (should (equal '(integer 1) (harness-reloadtest-made 1)))
    (should-not (plist-get (harness--reload) :unbound))
    (should (equal '(integer 2) (harness-reloadtest-made 2)))
    ;; The file drops both, and neither is unbound.
    (funcall write "a" '(defun harness-reloadtest-kept () 1))
    (should-not (plist-get (harness--reload) :unbound))
    (should (fboundp 'harness-reloadtest-made))
    (should (fboundp 'harness-reloadtest-declared))))

(ert-deftest harness-loader-reload-keeps-a-subr-a-load-named ()
  "A function that is a subr stays defined: it is none of the file's.
Native compilation defines the trampoline of a primitive that a file
advises as `--anonymous-lambda' while the file loads, and Emacs
records that in the file's entry.  An alias of a primitive stands in."
  (harness-core-test-with-reload-tree
    (funcall write "a"
             '(defalias 'harness-reloadtest-primitive (symbol-function 'car))
             '(defun harness-reloadtest-removed () 1))
    (should (harness-start))
    (should (subrp (symbol-function 'harness-reloadtest-primitive)))
    (funcall write "a")
    (should (equal '(harness-reloadtest-removed) (plist-get (harness--reload) :unbound)))
    (should (eq 1 (harness-reloadtest-primitive '(1 2))))))

(ert-deftest harness-loader-reload-snapshot-leaves-the-libraries-it-is-told-failed ()
  "The function `harness--reload-snapshot' returns unbinds nothing of a failed library.
Told which libraries failed to load it leaves their functions, whatever
`load-history' says of them; told none it unbinds what they dropped."
  (harness-core-test-with-reload-tree
    (let ((file (expand-file-name "lisp/modules/harness-reloadtest-a.el" tree)))
      (funcall write "a"
               '(defun harness-reloadtest-kept () 1)
               '(defun harness-reloadtest-removed () 2))
      (harness-load-compiled file)
      (let ((unbind (harness--reload-snapshot)))
        (funcall write "a" '(defun harness-reloadtest-kept () 1))
        (harness-load-compiled file)
        (should-not (funcall unbind '("harness-reloadtest-a")))
        (should (fboundp 'harness-reloadtest-removed))
        (should (equal '(harness-reloadtest-removed) (funcall unbind '("harness-reloadtest-b"))))
        (should-not (fboundp 'harness-reloadtest-removed))
        (should (fboundp 'harness-reloadtest-kept))))))

(ert-deftest harness-loader-reload-unbinds-nothing-of-a-file-that-failed-to-load ()
  "A file that does not load keeps its old entry of `load-history', and its functions.
The next reload that loads it unbinds what it no longer defines."
  (harness-core-test-with-reload-tree
    (funcall write "a"
             '(defun harness-reloadtest-kept () 1)
             '(defun harness-reloadtest-removed () 2))
    (funcall write "b" '(defun harness-reloadtest-b-old () 'b))
    (should (harness-start))
    ;; Rewritten without a function, but it fails half way; the file
    ;; that loads after it renames one, which goes.
    (funcall write "a" '(defun harness-reloadtest-kept () 1) '(error "Half way"))
    (funcall write "b" '(defun harness-reloadtest-b-new () 'b))
    (let ((result (harness--reload)))
      (should (= 1 (length (plist-get result :errors))))
      (should (string-match-p "harness-reloadtest-a.el: Half way" (car (plist-get result :errors))))
      (should (equal '(harness-reloadtest-b-old) (plist-get result :unbound))))
    (should (fboundp 'harness-reloadtest-removed))
    (should-not (fboundp 'harness-reloadtest-b-old))
    ;; Mended, it loads, and what it dropped goes.
    (funcall write "a" '(defun harness-reloadtest-kept () 1))
    (let ((result (harness--reload)))
      (should-not (plist-get result :errors))
      (should (equal '(harness-reloadtest-removed) (plist-get result :unbound))))
    (should-not (fboundp 'harness-reloadtest-removed))
    (should (fboundp 'harness-reloadtest-kept))))

;;;; Modules of the user's own

(defun harness-core-test--write-elisp (file &rest forms)
  "Write FORMS to FILE, a file of lexical Emacs Lisp."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert ";;; -*- lexical-binding: t -*-\n")
    (dolist (form forms)
      (prin1 form (current-buffer))
      (insert "\n"))))

(ert-deftest harness-loader-picks-extra-modules-by-side ()
  "Which modules of `harness-extra-module-directories' an Emacs loads.
They load after the harness's own.  A UI module (ui-NAME) loads where
lisp/ui does and any other where lisp/modules does: both in a harness
with no process of its own, only the UI ones in the UI of a harness
process, and only the others in that process.  One whose name the
harness has already, a library's included, is left out with a warning;
the enabled and disabled lists select them as they do the harness's own."
  (let* ((config (harness-test-temp-dir))
         (mine (expand-file-name "my-modules/" config))
         (warned nil)
         (harness-log-hook
          (list (lambda (level msg)
                  (when (and (eq level 'warn) (string-match "\\`module \\([^:]+\\): .* is left out" msg))
                    (push (match-string 1 msg) warned)))))
         (left-out (lambda () (prog1 (sort warned #'string<) (setq warned nil))))
         (user-emacs-directory config)
         ;; Relative to `user-emacs-directory'; one that does not exist is
         ;; no error.
         (harness-extra-module-directories '("my-modules" "/nonexistent/harness-modules"))
         (harness-enabled-modules t)
         (harness-disabled-modules nil)
         (mine-of (lambda (files)
                    (mapcar #'file-name-nondirectory
                            (cl-remove-if-not (lambda (f) (string-prefix-p mine f)) files)))))
    (dolist (name '("hello" "ui-hello" "session" "ui-chat" "files"))
      (harness-core-test--write-elisp (expand-file-name (format "harness-%s.el" name) mine)
                                      '(ignore)))
    ;; Not modules: the files a module of the directory may require.
    (harness-core-test--write-elisp (expand-file-name "hello-util.el" mine) '(ignore))
    (harness-core-test--write-elisp (expand-file-name "harness_hello.el" mine) '(ignore))
    (unwind-protect
        (progn
          ;; A harness with no process of its own loads both, after its own.
          (let* ((harness-process nil)
                 (harness-module-directories '("lisp/modules" "lisp/ui"))
                 (files (harness--module-files)))
            (should (equal (list (expand-file-name "harness-hello.el" mine)
                                 (expand-file-name "harness-ui-hello.el" mine))
                           (last files 2)))
            (should (equal '("harness-hello.el" "harness-ui-hello.el") (funcall mine-of files)))
            ;; The harness's own of the names taken stay.
            (should (member (harness--path "lisp/modules/harness-session.el") files))
            (should (member (harness--path "lisp/ui/harness-ui-chat.el") files))
            (should (equal '("files" "session" "ui-chat") (funcall left-out))))
          ;; The UI of a harness process loads the UI one.
          (let ((harness-process t)
                (harness-module-directories '("lisp/modules" "lisp/ui")))
            (should (equal '("harness-ui-hello.el") (funcall mine-of (harness--module-files))))
            (should (equal '("ui-chat") (funcall left-out))))
          ;; The harness process, which loads lisp/modules, the other.
          (let ((harness-process nil)
                (harness-module-directories '("lisp/modules")))
            (should (equal '("harness-hello.el") (funcall mine-of (harness--module-files))))
            (should (equal '("files" "session") (funcall left-out))))
          ;; The enabled and disabled lists name them as they do any other.
          (let ((harness-process nil)
                (harness-module-directories '("lisp/modules" "lisp/ui")))
            ;; A module's UI half is disabled with it, not the other way.
            (let ((harness-disabled-modules '(hello)))
              (should-not (funcall mine-of (harness--module-files))))
            (let ((harness-disabled-modules '(ui-hello)))
              (should (equal '("harness-hello.el") (funcall mine-of (harness--module-files)))))
            ;; Not enabled, they do not load; enabled, one brings its other half.
            (let ((harness-enabled-modules nil))
              (should-not (funcall mine-of (harness--module-files))))
            (dolist (one '(hello ui-hello))
              (let ((harness-enabled-modules (list one)))
                (should (equal '("harness-hello.el" "harness-ui-hello.el")
                               (funcall mine-of (harness--module-files))))))))
      (delete-directory config t))))

(ert-deftest harness-loader-loads-supervisor-mode-and-readonly-by-default ()
  "By default supervisor mode loads, beside the readonly module it shares.
The task board's write-ups and plans use that module too, so it loads
on its own, and taking supervisor mode's two modules out leaves it in."
  (let* ((harness-enabled-modules t)
         (harness-disabled-modules (eval (car (get 'harness-disabled-modules 'standard-value)) t))
         (harness-extra-module-directories nil)
         (harness-process nil)
         (harness-module-directories '("lisp/modules" "lisp/ui"))
         (files (harness--module-files)))
    (should-not harness-disabled-modules)
    (dolist (file '("lisp/modules/harness-supervisor.el" "lisp/ui/harness-ui-supervisor.el"
                    "lisp/modules/harness-readonly.el" "lisp/modules/harness-tasks.el"))
      (should (member (harness--path file) files)))
    (let ((harness-disabled-modules '(supervisor ui-supervisor)))
      (let ((files (harness--module-files)))
        (should-not (member (harness--path "lisp/modules/harness-supervisor.el") files))
        (should (member (harness--path "lisp/modules/harness-readonly.el") files))))))

(ert-deftest harness-loader-starts-and-reloads-extra-modules ()
  "Modules of `harness-extra-module-directories' start and reload as the harness's own.
They load compiled and record their source, not that compiled copy.
They require the other files of their directory, which is on
`load-path'.  `harness-reload' loads them again: it refuses a broken
edit, naming the file, and picks up a good one."
  (harness-test-reset-bus)
  (harness-test-with-temp-state
    (let* ((tree (harness-test-temp-dir))
           (config (harness-test-temp-dir))
           (mine (expand-file-name "my-modules/" config))
           (hello (expand-file-name "harness-hello.el" mine))
           (ui-hello (expand-file-name "harness-ui-hello.el" mine))
           (write-hello
            (lambda (fmt)
              (harness-core-test--write-elisp
               hello
               '(require 'harness-core)
               '(require 'hello-util)
               '(defcustom harness-hello-greeting "hello" "How to greet."
                  :type 'string :group 'harness)
               `(harness-defmethod hello/greet (name)
                  "Greet NAME."
                  (format ,fmt (hello-util-greet harness-hello-greeting name)))
               '(harness-define-module 'hello :doc "Says hello.")
               '(provide 'harness-hello)))))
      (harness-core-test--write-elisp (expand-file-name "lisp/modules/harness-own.el" tree)
                                      '(harness-define-module 'own :doc "The harness's own.")
                                      '(provide 'harness-own))
      (harness-core-test--write-elisp (expand-file-name "hello-util.el" mine)
                                      '(defun hello-util-greet (greeting name)
                                         (format "%s, %s" greeting name))
                                      '(provide 'hello-util))
      (funcall write-hello "%s")
      (harness-core-test--write-elisp ui-hello
                                      '(require 'harness-core)
                                      '(defun harness-ui-hello-greet (name)
                                         (harness-call 'hello/greet name))
                                      '(harness-define-module 'ui-hello :doc "Its UI."
                                                              :requires '(hello))
                                      '(provide 'harness-ui-hello))
      (unwind-protect
          (cl-letf (((symbol-function 'harness--path)
                     (lambda (rel) (expand-file-name rel tree))))
            (let ((harness-module-directories '("lisp/modules" "lisp/ui"))
                  (harness--core-files nil)
                  (harness--library-files nil)
                  (harness-process nil)
                  (harness-enabled-modules t)
                  (harness-disabled-modules nil)
                  (user-emacs-directory config)
                  (harness-extra-module-directories '("my-modules"))
                  (load-path load-path))
              (should (harness-start))
              (should (equal '(hello own ui-hello) (mapcar #'harness-module-name (harness-modules))))
              (should (harness-module-ready-p 'ui-hello))
              (should (equal "hello, you" (harness-ui-hello-greet "you")))
              ;; Compiled, in the state directory; the module records its source.
              (should (funcall (if (fboundp 'compiled-function-p) #'compiled-function-p #'byte-code-function-p)
                               (symbol-function 'harness-ui-hello-greet)))
              (should (equal (harness--compiled-name hello) (symbol-file 'harness-hello-greeting 'defvar)))
              (should (equal hello (harness-module-file (harness-module-get 'hello))))
              (should (equal (list hello ui-hello)
                             (mapcar (lambda (d) (plist-get d :file))
                                     (cl-remove 'own (harness-module-descriptions)
                                                :key (lambda (d) (plist-get d :name))))))
              ;; On `load-path', after everything else.
              (should (equal (directory-file-name mine) (car (last load-path))))
              ;; A broken edit is refused and leaves the old definitions.
              (with-temp-file hello (insert "(harness-define-module 'hello :init (lambda () (oops"))
              (let ((problems (plist-get (harness--reload) :refused)))
                (should (equal 1 (length problems)))
                (should (string-prefix-p "harness-hello.el: " (car problems))))
              (should (equal "hello, you" (harness-ui-hello-greet "you")))
              ;; A good one is picked up, and the module stays ready.
              (funcall write-hello "%s!")
              (should (harness-reload))
              (should (equal "hello, you!" (harness-ui-hello-greet "you")))
              (should (harness-module-ready-p 'hello))
              (should (equal hello (harness-module-file (harness-module-get 'hello))))
              (harness-stop)))
        (fmakunbound 'harness-ui-hello-greet)
        (fmakunbound 'hello-util-greet)
        (makunbound 'harness-hello-greeting)
        (setq features (cl-remove-if (lambda (f) (memq f '(harness-own harness-hello harness-ui-hello hello-util)))
                                     features))
        (delete-directory tree t)
        (delete-directory config t)))))

;;;; Projects' plugins

(defvar harness-core-test--seen nil "What the files a test loads saw, newest first.")
(defvar harness-core-test--inits nil "The modules a test saw start, newest first.")

(ert-deftest harness-core-plugin-modules-are-those-the-harness-did-not-load ()
  "A module is a plugin when the harness did not load it from its own directories.
Those are lisp/modules and lisp/ui in its tree and the directories of
`harness-extra-module-directories'; a module registered from a file
anywhere else -- a project's plugin, which its .dir-locals.el requires
-- is a plugin, and one without a file, defined by hand, is not.  The
loader knows no plugin directory: a project's .harness/plugins/ is
none of its."
  (harness-test-reset-bus)
  (let* ((config (harness-test-temp-dir))
         (project (harness-test-temp-dir))
         (mine (expand-file-name "my-modules/" config))
         (plugin (expand-file-name ".harness/plugins/dev/" project))
         (user-emacs-directory config)
         (harness-extra-module-directories '("my-modules"))
         (define (lambda (name file)
                   (let ((harness--defining-module name)
                         (harness--defining-file file))
                     (harness-define-module name)))))
    (unwind-protect
        (progn
          (make-directory mine t)
          (make-directory plugin t)
          (funcall define 'own (harness--path "lisp/modules/harness-own.el"))
          (funcall define 'ui-own (harness--path "lisp/ui/harness-ui-own.el"))
          (funcall define 'mine (expand-file-name "harness-mine.el" mine))
          (funcall define 'hello (expand-file-name "harness-hello.el" plugin))
          (harness-define-module 'by-hand)
          (should-not (harness-module-plugin-p 'own))
          (should-not (harness-module-plugin-p 'ui-own))
          (should-not (harness-module-plugin-p 'mine))
          (should-not (harness-module-plugin-p 'by-hand))
          (should-not (harness-module-plugin-p 'unknown))
          (should (harness-module-plugin-p 'hello))
          ;; The loader looks in its own directories only.
          (let ((harness-process nil)
                (harness-module-directories '("lisp/modules" "lisp/ui")))
            (should-not (cl-some (lambda (f) (string-prefix-p project f)) (harness--module-files)))))
      (harness-test-reset-bus)
      (dolist (dir (list config project)) (delete-directory dir t)))))

(ert-deftest harness-core-loading-module-follows-the-file ()
  "What a file loading defines belongs to the module the file is named after.
harness-NAME.el, or its compiled copy, holds module NAME, whoever loads
it: even while the harness loads a module of its own, as when that
module's `provide' lets a project's plugin load.  A file of another
name keeps the module the harness is loading, and outside any load
there is none."
  (let* ((dir (harness-test-temp-dir))
         (plugin (expand-file-name "harness-hello.el" dir))
         (other (expand-file-name "hello-util.el" dir))
         (seen nil))
    (unwind-protect
        (progn
          (harness-core-test--write-elisp plugin '(push (cons 'hello (harness-loading-module)) harness-core-test--seen))
          (harness-core-test--write-elisp other '(push (cons 'util (harness-loading-module)) harness-core-test--seen))
          (setq harness-core-test--seen nil)
          (let ((harness--defining-module 'tools))
            (load plugin nil t)
            (load other nil t)
            (should (eq 'tools (harness-loading-module))))
          (setq seen harness-core-test--seen)
          (should (equal '((util . tools) (hello . hello)) seen))
          (should-not (harness-loading-module)))
      (delete-directory dir t))))

(ert-deftest harness-core-late-modules-start-by-themselves ()
  "A module that code other than the harness defines once it started starts.
It starts as soon as the file defining it has loaded, not before, so
an init function defined further down is there.  One the harness
loads itself, or one defined before the harness started, waits for
the harness, and `harness-disabled-modules' keeps one from starting."
  (harness-test-reset-bus)
  (setq harness-core-test--inits nil)
  (let ((harness-started t)
        (harness-disabled-modules '(off)))
    (harness-define-module 'late :init (lambda () (push 'late harness-core-test--inits)))
    (harness-define-module 'off :init (lambda () (push 'off harness-core-test--inits)))
    (let ((harness--defining-module 'loaded))
      (harness-define-module 'loaded :init (lambda () (push 'loaded harness-core-test--inits))))
    (should-not harness-core-test--inits)
    (harness-test-wait (lambda () (harness-module-ready-p 'late)) 5 "the late module")
    (accept-process-output nil 0.05)
    (should (equal '(late) harness-core-test--inits))
    (should (eq 'registered (harness-module-state (harness-module-get 'off))))
    (should (eq 'registered (harness-module-state (harness-module-get 'loaded)))))
  (let ((harness-started nil))
    (harness-define-module 'early)
    (accept-process-output nil 0.05)
    (should (eq 'registered (harness-module-state (harness-module-get 'early)))))
  (harness-test-reset-bus))

;;;; Which modules load

(defvar harness-core-test--inits nil
  "The modules of `harness-core-test-with-module-tree' in the order they initialised.")

(defmacro harness-core-test-with-module-tree (&rest body)
  "Run BODY in a harness tree of small modules, the core being base and ui.
lisp/modules has base; feat, which requires base, and its UI half
ui-feat; extra, which requires feat and whose file requires lib, a
library; and other.  lisp/ui has ui, ui-feat and ui-solo, a UI with no
other half.  Each module notes its initialisation in
`harness-core-test--inits'.  `tree' is bound to the tree in BODY."
  (declare (indent 0))
  `(let ((tree (harness-test-temp-dir))
         (had-ui (featurep 'harness-ui)))
     (harness-test-reset-bus)
     (setq harness-core-test--inits nil)
     ;; A reload loads harness.el first: the real one would put back the
     ;; `harness--path' and the core this replaces.
     (harness-core-test--write-elisp (expand-file-name "harness.el" tree) '(ignore))
     (pcase-dolist (`(,file ,name ,requires . ,forms)
                    '(("lisp/modules/harness-base.el" base nil)
                      ("lisp/modules/harness-feat.el" feat (base))
                      ("lisp/modules/harness-extra.el" extra (feat)
                       (require 'harness-feat) (require 'harness-lib))
                      ("lisp/modules/harness-lib.el" nil nil (defun harness-lib-answer () 42))
                      ("lisp/modules/harness-other.el" other nil)
                      ("lisp/ui/harness-ui.el" ui nil)
                      ("lisp/ui/harness-ui-feat.el" ui-feat (ui))
                      ("lisp/ui/harness-ui-solo.el" ui-solo (ui))))
       (apply #'harness-core-test--write-elisp (expand-file-name file tree)
              (append forms
                      (and name
                           `((harness-define-module ',name
                               :doc ,(format "The %s module." name)
                               :requires ',requires
                               :init (lambda () (push ',name harness-core-test--inits)))))
                      `((provide ',(intern (file-name-base file)))))))
     (unwind-protect
         (cl-letf (((symbol-function 'harness--path)
                    (lambda (rel) (expand-file-name rel tree))))
           (let ((harness--self-file (expand-file-name "harness.el" tree))
                 (harness-module-directories '("lisp/modules" "lisp/ui"))
                 (harness--core-files nil)
                 (harness--library-files nil)
                 (harness-process nil)
                 (harness-extra-module-directories nil)
                 (harness-core-modules '(base ui))
                 (harness-enabled-modules nil)
                 (harness-disabled-modules nil)
                 (harness-started nil)
                 (load-path load-path))
             ,@body))
       (dolist (f '(harness-base harness-feat harness-extra harness-lib harness-other
                    harness-ui-feat harness-ui-solo))
         (setq features (delq f features)))
       (unless had-ui (setq features (delq 'harness-ui features)))
       (fmakunbound 'harness-lib-answer)
       (harness-test-reset-bus)
       (delete-directory tree t))))

(defun harness-core-test--loads ()
  "Return the names of the module files `harness--module-files' returns."
  (mapcar #'harness--file-module-name (harness--module-files)))

(ert-deftest harness-loader-loads-the-core-and-what-is-enabled ()
  "Out of the box only the core loads; each module enabled brings what it needs.
That is the modules and libraries it requires, by its :requires or by
its file's requires, and its other half, ui-NAME for NAME and NAME for
ui-NAME.  t loads every module, and a disabled module stays out with
its UI half, whatever brings it."
  (harness-core-test-with-module-tree
    (should (equal '(base ui) (harness-core-test--loads)))
    (let ((harness-enabled-modules '(extra)))
      (should (equal '(base extra feat lib ui-feat ui) (harness-core-test--loads))))
    (let ((harness-enabled-modules '(ui-feat)))
      (should (equal '(base feat ui-feat ui) (harness-core-test--loads))))
    (let ((harness-enabled-modules '(ui-solo)))
      (should (equal '(base ui-solo ui) (harness-core-test--loads))))
    (let ((harness-enabled-modules t))
      (should (equal '(base extra feat lib other ui-feat ui-solo ui) (harness-core-test--loads))))
    (let ((harness-enabled-modules '(extra))
          (harness-disabled-modules '(feat)))
      (should (equal '(base extra lib ui) (harness-core-test--loads))))
    (let ((harness-enabled-modules t)
          (harness-disabled-modules '(feat base)))
      (should (equal '(extra lib other ui-solo ui) (harness-core-test--loads))))
    ;; Each side loads its own.
    (let ((harness-enabled-modules '(extra))
          (harness-module-directories '("lisp/modules")))
      (should (equal '(base extra feat lib) (harness-core-test--loads))))
    (should (harness-module-default-p 'base))
    (should-not (harness-module-default-p 'extra))
    (let ((harness-enabled-modules '(extra nope ui-solo)))
      (should (equal '(nope) (harness--unknown-modules))))))

(ert-deftest harness-loader-core-of-the-harness ()
  "The harness's own core, and the UI halves named after their modules.
Every name of `harness-core-modules' is a module of the harness.  Out
of the box session names, worktrees and the agent tools load, each
tool a module of its own; the task board, merges, serving other
devices and handoffs wait to be enabled, each with its UI half."
  (let ((sources (harness--module-sources))
        (harness-enabled-modules nil)
        (harness-disabled-modules nil))
    (dolist (name harness-core-modules)
      (should (assq name sources)))
    (dolist (name '(naming worktree ui-worktree tools-agent tools-question tools-plan
                    tools-todo tools-session-info))
      (should (harness-module-default-p name)))
    (dolist (name '(tasks merge acp-remote ui-acp-remote handoff ui-handoff))
      (should-not (harness-module-default-p name)))
    ;; The halves of a feature bring each other along by their names: a UI
    ;; half requires none of the harness's modules (see the test below).
    (pcase-dolist (`(,name . ,ui) '((acp-remote . ui-acp-remote) (handoff . ui-handoff)
                                    (patch-review . ui-patch-review)))
      (should (memq ui (harness--module-closure sources (list name))))
      (should (memq name (harness--module-closure sources (list ui)))))))

(ert-deftest harness-loader-modules-require-only-what-loads-where-they-do ()
  "A module requires only modules that load in the Emacs it runs in.
With `harness-process' on, the default, the user's Emacs loads the UI
modules and the ACP client and the harness process loads the modules of
lisp/modules, so a module whose requirement loads on the other side
never starts (`harness-module-start'): `ui-patch-review' once required
its harness half, `patch-review', and so failed in every Emacs that runs
the harness as it is by default -- the changes of a task in review never
showed in its report.  The two halves of a feature talk over ACP and
never require each other, and the loader brings the other half along by
its name (`harness--module-other-half').  A requirement is a module its
`:requires' names or one whose file its file requires
\(`harness--module-header'); a library of lisp/ is no module."
  (let* ((harness-enabled-modules t)
         (harness-disabled-modules nil)
         (harness-extra-module-directories nil)
         (sources (harness--module-sources))
         (sides `((ui-emacs
                   . ,(let ((harness-process t)
                            (harness-module-directories '("lisp/modules" "lisp/ui")))
                        (mapcar #'harness--file-module-name (harness--module-files))))
                  (harness-process
                   . ,(let ((harness-process nil)
                            (harness-module-directories '("lisp/modules")))
                        (mapcar #'harness--file-module-name (harness--module-files)))))))
    ;; Each side loads its own and not the other's, or the loop below
    ;; would check nothing.
    (should (memq 'ui-patch-review (alist-get 'ui-emacs sides)))
    (should (memq 'acp (alist-get 'ui-emacs sides)))
    (should-not (memq 'patch-review (alist-get 'ui-emacs sides)))
    (should (memq 'patch-review (alist-get 'harness-process sides)))
    (should-not (memq 'ui-patch-review (alist-get 'harness-process sides)))
    (pcase-dolist (`(,side . ,loaded) sides)
      (dolist (name loaded)
        (dolist (required (plist-get (harness--module-header (alist-get name sources)) :requires))
          (when (assq required sources)
            (ert-info ((format "%s, in the %s, requires %s, which loads only in the other"
                               name side required))
              (should (memq required loaded)))))))))

(ert-deftest harness-enable-modules-reads-groups ()
  "`harness-enable-modules' names modules in groups, as Doom's init.el does."
  (let ((harness-enabled-modules '(old)))
    (harness-enable-modules
      tasks
      :features merge ;;pet
      :providers openai provider-bedrock
      :tools web
      :ui tree)
    (should (equal '(tasks merge provider-openai provider-bedrock tools-web ui-tree)
                   harness-enabled-modules)))
  (should-error (harness--module-names '(:nope x)))
  (should-error (harness--module-names '(:features "x"))))

(ert-deftest harness-enable-module-loads-and-starts-in-dependency-order ()
  "\\[harness-enable-module] loads a module with what it brings and starts them.
They start after what they require, and enabling it again, or a module
it brought, starts nothing again.  A reload after it is no longer
enabled says it runs on until a restart."
  (harness-core-test-with-module-tree
    (should (harness-start))
    (should (equal '(base ui) (reverse harness-core-test--inits)))
    (setq harness-core-test--inits nil)
    (harness-enable-module 'extra)
    (should (equal '(extra) harness-enabled-modules))
    (let ((order (reverse harness-core-test--inits)))
      (should (equal '(extra feat ui-feat) (sort (copy-sequence order) #'string<)))
      (should (< (cl-position 'feat order) (cl-position 'extra order))))
    (should (cl-every #'harness-module-ready-p '(base ui feat extra ui-feat)))
    (should (= 42 (harness-lib-answer)))
    (should (funcall (if (fboundp 'compiled-function-p) #'compiled-function-p #'byte-code-function-p)
                     (symbol-function 'harness-lib-answer)))
    ;; Again, and a module it brought: nothing more starts.
    (setq harness-core-test--inits nil)
    (harness-enable-module 'extra)
    (harness-enable-module 'feat)
    (should-not harness-core-test--inits)
    (should (equal '(extra) harness-enabled-modules))
    (should-error (harness-enable-module 'nope) :type 'user-error)
    (let ((harness-disabled-modules '(other)))
      (should-error (harness-enable-module 'other) :type 'user-error))
    ;; The modules that could be enabled still, as the module list shows them.
    (let ((section (harness--modules-not-loaded)))
      (should (string-match-p "not loaded" (car section)))
      (should (equal '((other available "The other module.") (ui-solo available "The ui-solo module."))
                     (mapcar (lambda (d) (list (plist-get d :name) (plist-get d :state) (plist-get d :doc)))
                             (harness-test-await (cdr section))))))
    ;; No longer enabled: a reload says the modules run on until a restart.
    (setq harness-enabled-modules nil)
    (let ((result (harness--reload)))
      (should-not (plist-get result :errors))
      (should (equal '(extra feat ui-feat)
                     (sort (copy-sequence (plist-get result :stale)) #'string<))))
    (should (harness-module-ready-p 'extra))
    (harness-stop)))

;;;; Vendored libraries

(ert-deftest harness-vendored-directories-lists-the-libraries ()
  "Each subdirectory of lisp/vendor is a library, listed sorted and absolute.
A plain file there, such as the README, and a hidden directory are not
libraries; a tree without lisp/vendor has none.  The harness's own tree
is the default."
  (let ((root (harness-test-temp-dir)))
    (unwind-protect
        (progn
          (should-not (harness--vendored-directories root))
          (make-directory (expand-file-name "lisp" root))
          (should-not (harness--vendored-directories root))
          (dolist (name '("lisp/vendor/b" "lisp/vendor/a" "lisp/vendor/.hidden"))
            (make-directory (expand-file-name name root) t))
          (with-temp-file (expand-file-name "lisp/vendor/README.md" root)
            (insert "# Vendored libraries\n"))
          (should (equal (list (expand-file-name "lisp/vendor/a" root)
                               (expand-file-name "lisp/vendor/b" root))
                         (harness--vendored-directories root)))
          (let ((harness-directory root))
            (should (equal (harness--vendored-directories root) (harness--vendored-directories)))))
      (delete-directory root t))))

(ert-deftest harness-vendored-directories-are-on-the-load-path ()
  "`harness--setup-load-path' puts each vendored library's directory on `load-path'.
A library is found by its name there, ahead of the directories of the
user's own modules, which stay last."
  (let* ((libraries (harness--vendored-directories))
         (config (harness-test-temp-dir))
         (mine (expand-file-name "my-modules" config))
         (user-emacs-directory config)
         (harness-extra-module-directories '("my-modules"))
         ;; This Emacs's, without the libraries' directories.
         (load-path (cl-remove-if (lambda (dir) (and (stringp dir) (member (directory-file-name dir) libraries)))
                                  load-path)))
    ;; None found would pass the checks below without checking anything.
    (should (member "compose-quote" (mapcar #'file-name-nondirectory libraries)))
    (unwind-protect
        (progn
          (make-directory mine t)
          (should-not (cl-intersection libraries load-path :test #'equal))
          (harness--setup-load-path)
          (dolist (dir libraries)
            (should (member dir load-path))
            (should (< (cl-position dir load-path :test #'equal)
                       (cl-position mine load-path :test #'equal))))
          (should (equal mine (car (last load-path))))
          (should (equal (expand-file-name "lisp/vendor/compose-quote/" harness-directory)
                         (file-name-directory (locate-library "compose-quote")))))
      (delete-directory config t))))

(ert-deftest harness-loading-harness-el-finds-the-vendored-libraries ()
  "An Emacs that only loads harness.el has the vendored libraries on its load path.
So does the harness process, and so does a harness older than this one
when it checks an update: it loads the new harness.el before it compiles
the files of the new tree, and the compose box requires `compose-quote'."
  (let ((emacs (expand-file-name invocation-name invocation-directory))
        (expected (expand-file-name "lisp/vendor/compose-quote/compose-quote.el" harness-test-root)))
    (with-temp-buffer
      (let* ((status (call-process emacs nil t nil "-Q" "--batch"
                                   "-l" (expand-file-name "harness.el" harness-test-root)
                                   "--eval" "(princ (locate-library \"compose-quote\"))"))
             (output (buffer-string)))
        (ert-info (output)
          (should (eql 0 status))
          (should (equal (file-truename expected)
                         (file-truename (car (last (split-string output "\n" t)))))))))))

(ert-deftest harness-library-files-are-there ()
  "Every library file the harness loads exists, the vendored compose-quote among them.
The compose box quotes with it, so it loads compiled at start and again
at every reload, as the harness's other libraries do."
  (dolist (file harness--library-files)
    (should (file-regular-p (harness--path file))))
  (should (member "lisp/vendor/compose-quote/compose-quote.el" harness--library-files))
  ;; change-review, which a task's review is made with, in the order its
  ;; files require each other.
  (should (equal '("lisp/vendor/change-review/change-review.el"
                   "lisp/vendor/change-review/change-review-diff.el"
                   "lisp/vendor/change-review/change-review-mail.el"
                   "lisp/vendor/change-review/change-review-ui.el")
                 (cl-remove-if-not (lambda (file) (string-prefix-p "lisp/vendor/change-review/" file))
                                   harness--library-files)))
  ;; worktree-assume, with which a task's worktree stands in for its
  ;; project: the task board and the worktree list use it.
  (should (member "lisp/vendor/worktree-assume/worktree-assume.el" harness--library-files)))

(ert-deftest harness-modules-find-their-libraries-with-an-old-load-path ()
  "The modules that require a vendored library compile where its directory is not on `load-path'.
A harness older than lisp/vendor, reloading after an update, first
compiles every file of the new tree with the `load-path' it has, which
lacks the library's directory: the modules look for it beside
themselves, as the compose box does for compose-quote, or the reload
is refused.  That goes for change-review, which the task review is
made with, and for worktree-assume, which the task board and the
worktree list use."
  (let ((emacs (expand-file-name invocation-name invocation-directory))
        (out (harness-test-temp-dir)))
    (unwind-protect
        (dolist (file '("lisp/modules/harness-patch-review.el" "lisp/ui/harness-ui-patch-review.el"
                        "lisp/ui/harness-ui-worktree.el" "lisp/ui/harness-ui-tasks.el"))
          (with-temp-buffer
            (let* ((elc (expand-file-name "checked.elc" out))
                   (status (call-process
                            emacs nil t nil "-Q" "--batch"
                            "-L" harness-test-root
                            "-L" (expand-file-name "lisp" harness-test-root)
                            "-L" (expand-file-name "lisp/modules" harness-test-root)
                            "-L" (expand-file-name "lisp/ui" harness-test-root)
                            "--eval"
                            (format "(progn (setq byte-compile-warnings nil
                                                  byte-compile-dest-file-function (lambda (_) %S))
                                            (kill-emacs (if (eq t (byte-compile-file %S)) 0 1)))"
                                    elc (expand-file-name file harness-test-root))))
                   (output (buffer-string)))
              (ert-info ((format "%s:\n%s" file output))
                (should (eql 0 status))))))
      (delete-directory out t))))

(ert-deftest harness-auto-reload-watches-the-vendored-libraries ()
  "`harness-auto-reload-mode' watches each vendored library's directory.
A change to a library reloads the harness like one to a module."
  (let ((watched nil)
        (harness--watches nil))
    (cl-letf (((symbol-function 'file-notify-add-watch)
               (lambda (dir _flags _callback) (push dir watched) dir))
              ((symbol-function 'file-notify-rm-watch) #'ignore))
      (unwind-protect
          (progn
            (harness-auto-reload-mode 1)
            (should (harness--vendored-directories))
            (dolist (dir (harness--vendored-directories))
              (should (member dir watched)))
            ;; Beside the harness's own directories.
            (should (member (harness--path "lisp/ui") watched)))
        (harness-auto-reload-mode -1)))))

(ert-deftest harness-loader-loads-vendored-libraries ()
  "A library file under lisp/vendor loads compiled at start and again at a reload.
Its directory is on `load-path', so a module can require another file of
the library, and a library that does not compile refuses the reload."
  (harness-test-reset-bus)
  (let* ((dir (harness-test-temp-dir))
         (lib (expand-file-name "lisp/vendor/vlib/vlib.el" dir))
         (moddir (expand-file-name "lisp/modules" dir))
         (version (lambda (n)
                    (harness-core-test--write-elisp lib `(defun vlib-answer () ,n) '(provide 'vlib)))))
    (make-directory moddir t)
    (funcall version 1)
    (harness-core-test--write-elisp (expand-file-name "lisp/vendor/vlib/vlib-extra.el" dir)
                                    '(defun vlib-extra-answer () 10)
                                    '(provide 'vlib-extra))
    (harness-core-test--write-elisp (expand-file-name "harness-vuser.el" moddir)
                                    '(require 'vlib-extra)
                                    '(harness-define-module 'vuser)
                                    '(harness-register-method 'vuser/answer
                                                              (lambda () (+ (vlib-answer) (vlib-extra-answer))))
                                    '(provide 'harness-vuser))
    (unwind-protect
        (cl-letf (((symbol-function 'harness--path)
                   (lambda (rel) (expand-file-name rel dir))))
          (let ((harness-module-directories '("lisp/modules"))
                (harness--core-files nil)
                (harness--library-files '("lisp/vendor/vlib/vlib.el"))
                (harness-enabled-modules '(vuser))
                (harness-process nil)
                (load-path load-path))
            (should (harness-start))
            (should (equal 11 (harness-call 'vuser/answer)))
            (should (funcall (if (fboundp 'compiled-function-p) #'compiled-function-p #'byte-code-function-p)
                             (symbol-function 'vlib-answer)))
            ;; Broken, it refuses the reload and the old definitions stay.
            (with-temp-file lib (insert "(defun vlib-answer () (oops"))
            (let ((problems (plist-get (harness--reload) :refused)))
              (should (equal 1 (length problems)))
              (should (string-prefix-p "vlib.el: " (car problems))))
            (should (equal 11 (harness-call 'vuser/answer)))
            ;; Updated, the reload loads it again.
            (funcall version 2)
            (should (harness-reload))
            (should (equal 12 (harness-call 'vuser/answer)))))
      (fmakunbound 'vlib-answer)
      (fmakunbound 'vlib-extra-answer)
      (setq features (cl-remove-if (lambda (f) (memq f '(vlib vlib-extra harness-vuser))) features))
      (delete-directory dir t))))

(ert-deftest harness-vendored-libraries-stand-alone ()
  "A vendored library needs nothing of the harness.
No Emacs Lisp file of one, its name or its text, mentions the harness,
and the suites of its tests pass in an Emacs with only the library's own
directory on `load-path', which knows nothing of the harness."
  (let ((libraries (harness--vendored-directories))
        (emacs (expand-file-name invocation-name invocation-directory))
        (suites 0))
    ;; None found would pass the checks below without checking anything.
    (should libraries)
    (dolist (dir libraries)
      (let ((mentions nil))
        (dolist (file (directory-files dir t "\\.el\\'"))
          (when (string-match-p "harness" (file-name-nondirectory file))
            (push (file-name-nondirectory file) mentions))
          (with-temp-buffer
            (insert-file-contents file)
            (let ((case-fold-search t))
              (while (re-search-forward "harness" nil t)
                (push (format "%s:%d" (file-name-nondirectory file) (line-number-at-pos)) mentions)))))
        (should-not mentions))
      (dolist (suite (directory-files dir t "-test\\.el\\'"))
        (with-temp-buffer
          (let* ((status (call-process emacs nil t nil "-Q" "--batch" "-L" dir "-l" suite
                                       "-f" "ert-run-tests-batch-and-exit"))
                 (output (buffer-string)))
            (ert-info ((format "%s:\n%s" (file-name-nondirectory suite) output))
              (should (eql 0 status)))
            (cl-incf suites)))))
    (should (> suites 0))))

(ert-deftest harness-core-describe-modules-lists-every-emacs ()
  "`harness-describe-modules' lists the modules of this Emacs, then of others.
A module from outside the harness's tree names its file, and a failed
one its error.  The modules of another Emacs, such as the harness
process, fill their section when they arrive, or it says why not."
  (harness-test-reset-bus)
  (let* ((outside (expand-file-name "harness-hello.el" (harness-test-temp-dir)))
         (process (harness-make-promise))
         (remote (harness-make-promise))
         (harness-describe-modules-functions
          (list (lambda () (cons "Modules of the harness process" process))
                #'ignore
                (lambda () (cons "Modules of the harness at there:1" remote)))))
    (let ((harness--defining-module 'own)
          (harness--defining-file (expand-file-name "lisp/modules/harness-own.el" harness-directory)))
      (harness-define-module 'own :doc "The harness's own."))
    (let ((harness--defining-module 'hello)
          (harness--defining-file outside))
      (harness-define-module 'hello :doc "Says hello."))
    ;; Defined as another module's file loads: its file is not that one.
    (let ((harness--defining-module 'hello)
          (harness--defining-file outside))
      (harness-define-module 'broken :doc "Fails." :init (lambda () (error "No luck"))))
    (harness-modules-init)
    (should-not (harness-module-file (harness-module-get 'broken)))
    (harness-describe-modules)
    (with-current-buffer harness--modules-buffer-name
      (let ((text (buffer-string)))
        (should (string-prefix-p "Modules of this Emacs\n\n" text))
        (should (string-match-p "^  broken +failed +Fails\\.\n +error: No luck\n" text))
        (should (string-match-p (concat "^  hello +ready +Says hello\\.\n +"
                                        (regexp-quote (abbreviate-file-name outside)) "\n")
                                text))
        ;; The harness's own names no file.
        (should (string-match-p "^  own +ready +The harness's own\\.\n\nModules of the harness process\n\n  …\n" text))
        (should (string-suffix-p "Modules of the harness at there:1\n\n  …\n" text))))
    (harness-resolve process (list (list :name 'session :state 'ready :doc "Sessions." :file nil :error nil)
                                   (list :name "hi" :state "failed" :doc "Hi." :file outside :error "Oops")))
    (harness-reject remote '(acp-error -32603 "Connection lost" nil))
    (harness-test-wait (lambda ()
                         (with-current-buffer harness--modules-buffer-name
                           (not (string-search "…" (buffer-string)))))
                       5 "the other Emacs's modules")
    (with-current-buffer harness--modules-buffer-name
      (let ((text (buffer-string)))
        (should (string-search
                 (concat "Modules of the harness process\n\n"
                         (format "  %-22s %-10s %s\n" "session" "ready" "Sessions.")
                         (format "  %-22s %-10s %s\n" "hi" "failed" "Hi.")
                         (format "  %-22s %-10s %s\n" "" "" (abbreviate-file-name outside))
                         (format "  %-22s %-10s error: %s\n" "" "" "Oops")
                         "\nModules of the harness at there:1\n\n"
                         "  They could not be listed: Connection lost\n")
                 text))))
    (kill-buffer harness--modules-buffer-name)))

(ert-deftest harness-util-run-command ()
  (let ((r (harness-await (harness-run-command '("sh" "-c" "echo out; echo err >&2; exit 3")))))
    (should (= 3 (plist-get r :exit)))
    (should (equal "out\n" (plist-get r :stdout)))
    (should (equal "err\n" (plist-get r :stderr))))
  (should (equal "abc" (plist-get (harness-await (harness-run-command '("cat") :stdin "abc")) :stdout)))
  (should (eq 'timeout (plist-get (harness-await (harness-run-command '("sleep" "5") :timeout 0.2)) :exit))))

(ert-deftest harness-util-process-send-waits-in-line ()
  "Writes to a process that does not read yet wait in line, never nested.
`process-send-string' runs the timers due while it waits for room; each
of them writing to the same process used to wait inside the one before,
which is how the harness process overflowed `max-lisp-eval-depth' and
died.  End-of-file asked for meanwhile goes out after what waits."
  (let* ((file (make-temp-file "harness-send-"))
         (proc (make-process :name "slow-reader" :noquery t :connection-type 'pipe
                             :command (list "sh" "-c" (format "sleep 1; cat > %s"
                                                              (shell-quote-argument file)))))
         (big (make-string 300000 ?a))
         (sending 0)
         (deepest 0))
    (unwind-protect
        (progn
          (dotimes (i 5)
            (run-at-time 0 nil (lambda ()
                                 (setq deepest (max deepest (cl-incf sending)))
                                 (unwind-protect
                                     (progn (harness-process-send proc (format "<%d>" i))
                                            (when (= i 4) (harness-process-send-eof proc)))
                                   (cl-decf sending)))))
          ;; This write fills the pipe and waits; the timers run inside it.
          (setq deepest (max deepest (cl-incf sending)))
          (harness-process-send proc big)
          (cl-decf sending)
          (harness-test-wait (lambda () (not (process-live-p proc))) 10 "the reader to see end-of-file")
          (should (= 2 deepest))
          (should-not (harness-process-sending-p proc))
          (should (equal (concat big "<0><1><2><3><4>")
                         (with-temp-buffer (insert-file-contents file) (buffer-string)))))
      (when (process-live-p proc) (delete-process proc))
      (delete-file file))))

(ert-deftest harness-util-process-send-gives-up-on-a-peer-that-stopped-reading ()
  "Past its limit, a write that waits for room gives the process up.
The write under way fails, so its caller drops the peer -- a phone put
away -- rather than pile up everything sent to it behind it."
  (let* ((proc (make-process :name "never-reads" :noquery t :connection-type 'pipe
                             :command '("sleep" "30")))
         (harness-process-send-slow 0.2)
         (logged nil)
         (log (lambda (level msg) (push (cons level msg) logged)))
         failed)
    (add-hook 'harness-log-hook log)
    (unwind-protect
        (progn
          (run-at-time 0.7 nil (lambda () (harness-process-send proc "late" 0.5)))
          (condition-case err
              (harness-process-send proc (make-string 300000 ?a) 0.5)
            (error (setq failed err)))
          (should failed)
          (should-not (process-live-p proc))
          (should-not (harness-process-sending-p proc))
          (should (cl-find-if (lambda (l) (string-match-p "a write to never-reads has waited" (cdr l))) logged))
          (should (cl-find-if (lambda (l) (string-match-p "never-reads has not read for" (cdr l))) logged)))
      (remove-hook 'harness-log-hook log)
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest harness-util-error-short-message-names-a-record-by-its-type ()
  "An error that names a record -- `args-out-of-range' and `wrong-type-argument'
do, of the struct they were about -- reads short: the record may hold a task's
hand-in, a branch's files with their diffs, a whole session.  Strings and lists
of the data are cut as before, and the message is one line at the limit."
  (let* ((record (record 'harness-test--review (make-string 5000 ?x)
                         (list :report (make-string 5000 ?y))))
         (short (harness-error-short-message (list 'args-out-of-range record 33))))
    (should (equal "Args out of range: \"#<harness-test--review>\", 33" short))
    (should (equal "Wrong type argument: change-review-set, \"#<harness-test--review>\""
                   (harness-error-short-message
                    (list 'wrong-type-argument 'change-review-set record)))))
  ;; In a list the error carries, at any depth.
  (let ((short (harness-error-short-message
                (list 'args-out-of-range (list :review (record 'harness-test--review "x") 1) 2))))
    (should (string-search "#<harness-test--review>" short)))
  ;; Whatever it prints is bounded, and cut to the limit.
  (let ((short (harness-error-short-message
                (list 'args-out-of-range (make-string 5000 ?z) 1) 80)))
    (should (<= (length short) 80))
    (should-not (string-match-p "\n" short))))

(defun harness-core-test-path (&rest specs)
  "Return a path of nodes from SPECS, each (ID KIND &optional META), oldest first."
  (mapcar (lambda (spec) (list :id (nth 0 spec) :kind (nth 1 spec) :meta (nth 2 spec))) specs))

(defun harness-core-test-ids (path)
  "Return the ids of the nodes of PATH."
  (mapcar (lambda (n) (plist-get n :id)) path))

(ert-deftest harness-util-a-compaction-is-in-force-until-it-is-reverted ()
  "A compaction node is in force, or reverted by its `:meta' `:reverted'.
The kind may be a symbol or its name, as a node arrives over the wire; the
mark is true or `:false', as JSON gives it; nothing but a compaction is either."
  (let ((live (list :kind 'compaction :meta '(:compaction "summary")))
        (reverted (list :kind "compaction" :meta '(:compaction "summary" :reverted t)))
        (restored (list :kind 'compaction :meta '(:compaction "summary" :reverted :false)))
        (user (list :kind 'user :meta '(:reverted t))))
    (should (harness-node-compaction-in-force-p live))
    (should-not (harness-node-compaction-reverted-p live))
    (should (harness-node-compaction-reverted-p reverted))
    (should-not (harness-node-compaction-in-force-p reverted))
    (should (harness-node-compaction-in-force-p restored))
    (should-not (harness-node-compaction-reverted-p user))
    (should-not (harness-node-compaction-in-force-p user))
    (should-not (harness-node-compaction-in-force-p nil))))

(ert-deftest harness-util-the-conversation-starts-at-the-compaction-in-force ()
  "A transcript starts at its last compaction that is in force, reverted ones being none."
  (let* ((reverted '(:reverted t))
         (path (harness-core-test-path '("a" user) '("b" assistant) '("c1" compaction) '("d" user)
                                       '("c2" compaction) '("e" user))))
    ;; Without a revert it is the last compaction.
    (should (eq path (harness-path-live path)))
    (should (equal '("c2" "e") (harness-core-test-ids (harness-path-from-compaction path))))
    ;; The last reverted: the one before it.
    (let ((path (harness-core-test-path '("a" user) '("b" assistant) '("c1" compaction) '("d" user)
                                        (list "c2" 'compaction reverted) '("e" user))))
      (should (equal '("a" "b" "c1" "d" "e") (harness-core-test-ids (harness-path-live path))))
      (should (equal '("c1" "d" "e") (harness-core-test-ids (harness-path-from-compaction path)))))
    ;; Both reverted: all of it, with neither compaction.
    (let ((path (harness-core-test-path '("a" user) '("b" assistant) (list "c1" 'compaction reverted)
                                        '("d" user) (list "c2" 'compaction reverted) '("e" user))))
      (should (equal '("a" "b" "d" "e") (harness-core-test-ids (harness-path-from-compaction path)))))
    ;; An older one reverted under a newer one in force changes nothing.
    (let ((path (harness-core-test-path '("a" user) (list "c1" 'compaction reverted) '("d" user)
                                        '("c2" compaction) '("e" user))))
      (should (equal '("c2" "e") (harness-core-test-ids (harness-path-from-compaction path)))))
    ;; No compaction at all.
    (should (equal '("a" "b") (harness-core-test-ids (harness-path-from-compaction
                                                      (harness-core-test-path '("a" user) '("b" assistant))))))
    (should-not (harness-path-from-compaction nil))))

(ert-deftest harness-util-a-reverted-compaction-gives-back-the-messages-it-carried-over ()
  "A message a compaction carried over after itself is dropped with a reverted
compaction when its original is on the path before it: the original is the
message then.  A copy whose original is not there stays, and so does a copy
of a compaction that is in force."
  (let* ((carried (lambda (id from) (list id 'user (list :carried-from from))))
         (reverted '(:reverted t)))
    ;; Reverted: the original, not the copy.
    (should (equal '("a" "u" "h" "e")
                   (harness-core-test-ids
                    (harness-path-live
                     (harness-core-test-path '("a" user) '("u" user) '("h" hint)
                                             (list "c" 'compaction reverted)
                                             (funcall carried "u2" "u") '("e" user))))))
    ;; In force: the copy stays, the original is before the compaction.
    (should (equal '("c" "u2" "e")
                   (harness-core-test-ids
                    (harness-path-from-compaction
                     (harness-core-test-path '("a" user) '("u" user) '("c" compaction)
                                             (funcall carried "u2" "u") '("e" user))))))
    ;; A copy of a message that is not on the path (a cut that kept the
    ;; original off it) stays.
    (should (equal '("a" "u2" "e")
                   (harness-core-test-ids
                    (harness-path-live
                     (harness-core-test-path '("a" user) (list "c" 'compaction reverted)
                                             (funcall carried "u2" "gone") '("e" user))))))
    ;; A copy of a copy: dropped with the compaction that made it, the
    ;; copy it was made from standing for it.
    (should (equal '("u" "c1" "u1" "e")
                   (harness-core-test-ids
                    (harness-path-live
                     (harness-core-test-path '("u" user) '("c1" compaction)
                                             (funcall carried "u1" "u")
                                             (list "c2" 'compaction reverted)
                                             (funcall carried "u2" "u1") '("e" user))))))))

(provide 'harness-core-test)
;;; harness-core-test.el ends here
