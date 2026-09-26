;;; harness-core-test.el --- Tests for the kernel -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'json)
(require 'harness-core)

(add-to-list 'load-path
             (expand-file-name "fixtures" (file-name-directory (or load-file-name buffer-file-name))))
(require 'harness-fixture-alpha)
(require 'harness-fixture-beta)

(defun harness-core-test--reset-fixtures ()
  "Unload the fixture modules and clear the fixture log."
  (dolist (module '(harness-fixture-beta harness-fixture-alpha))
    (when (harness-module-manifest module)
      (harness-module-unload module)))
  (setq harness-fixture-test-log nil)
  ;; Tests register anonymous handlers that have no owning module; drop them
  ;; so each test starts from the same state.
  (clrhash harness-core--event-handlers))

(ert-deftest harness-core-module-loads-dependencies-first ()
  (harness-core-test--reset-fixtures)
  (harness-module-load 'harness-fixture-beta)
  (should (equal (reverse harness-fixture-test-log)
                 '(alpha-setup beta-setup)))
  (should (harness-module-set-up-p 'harness-fixture-beta))
  (should (harness-module-set-up-p 'harness-fixture-alpha)))

(ert-deftest harness-core-module-load-is-idempotent ()
  (harness-core-test--reset-fixtures)
  (harness-module-load 'harness-fixture-alpha)
  (harness-module-load 'harness-fixture-alpha)
  (should (equal (reverse harness-fixture-test-log) '(alpha-setup))))

(ert-deftest harness-core-module-version-mismatch ()
  (harness-core-test--reset-fixtures)
  (should-error (harness-module-load 'harness-fixture-old-alpha)
                :type 'harness-module-error))

(ert-deftest harness-core-module-teardown-removes-registrations ()
  (harness-core-test--reset-fixtures)
  (harness-module-load 'harness-fixture-beta)
  (should (harness-service-available-p "alpha" 'echo))
  (should (harness-service-available-p "beta" 'hello))
  (harness-module-unload 'harness-fixture-beta)
  ;; beta's own service goes away, alpha's stays and alpha is still set up.
  (should-not (harness-service-available-p "beta"))
  (should (harness-service-available-p "alpha"))
  (harness-module-unload 'harness-fixture-alpha)
  (should-not (harness-service-available-p "alpha"))
  ;; the event handler registered by alpha must be gone
  (should (equal (gethash 'harness-fixture-ping harness-core--event-handlers nil) nil)))

(ert-deftest harness-core-event-handler-auto-removed-without-teardown ()
  (harness-core-test--reset-fixtures)
  (harness-module-load 'harness-fixture-alpha)
  (harness-module-unload 'harness-fixture-alpha)
  (should-not (gethash 'harness-fixture-ping harness-core--event-handlers)))

(ert-deftest harness-core-service-call ()
  (harness-core-test--reset-fixtures)
  (harness-module-load 'harness-fixture-alpha)
  (should (equal (harness-service-call "alpha" 'echo "x") "x"))
  (should (equal (harness-service-call "alpha" 'double 21) 42))
  (should-error (harness-service-call "alpha" 'nope) :type 'harness-service-missing)
  (should-error (harness-service-call "nope" 'echo) :type 'harness-service-missing))

(ert-deftest harness-core-service-introspection ()
  (harness-core-test--reset-fixtures)
  (harness-module-load 'harness-fixture-alpha)
  (should (member "alpha" (harness-service-list)))
  (should (equal (sort (harness-service-method-names "alpha") #'string<)
                 '(double echo)))
  (let ((description (harness-service-describe "alpha")))
    (should (eq (plist-get description :module) 'harness-fixture-alpha))
    (should (equal (plist-get description :doc) "Fixture service."))))

(ert-deftest harness-core-event-emit-and-handlers ()
  (harness-core-test--reset-fixtures)
  (harness-module-load 'harness-fixture-alpha)
  (harness-emit 'harness-fixture-ping :value 7)
  (should (equal (car harness-fixture-test-log) '(alpha-handled 7))))

(ert-deftest harness-core-event-predicate ()
  (harness-core-test--reset-fixtures)
  (let ((seen nil))
    (harness-on 'harness-fixture-ping
                (lambda (payload) (push (plist-get payload :value) seen))
                :predicate (lambda (payload) (= (plist-get payload :value) 1)))
    (harness-emit 'harness-fixture-ping :value 1)
    (harness-emit 'harness-fixture-ping :value 2)
    (should (equal seen '(1)))))

(ert-deftest harness-core-event-once ()
  (harness-core-test--reset-fixtures)
  (let ((count 0))
    (harness-once 'harness-fixture-ping (lambda (_) (cl-incf count)))
    (harness-emit 'harness-fixture-ping :value 1)
    (harness-emit 'harness-fixture-ping :value 2)
    (should (= count 1))))

(ert-deftest harness-core-event-handler-error-is-isolated ()
  (harness-core-test--reset-fixtures)
  (harness-module-load 'harness-fixture-alpha)
  (let ((second-ran nil))
    (harness-on 'harness-fixture-ping (lambda (_) (error "boom")))
    (harness-on 'harness-fixture-ping (lambda (_) (setq second-ran t)))
    (harness-emit 'harness-fixture-ping :value 1)
    (should second-ran)))

(ert-deftest harness-core-event-undeclared-signals ()
  (should-error (harness-emit 'harness-never-declared) :type 'harness-error))

(ert-deftest harness-core-event-key-replaces ()
  (harness-core-test--reset-fixtures)
  (let ((seen nil))
    (harness-on 'harness-fixture-ping (lambda (_) (push 'old seen)) :key 'k)
    (harness-on 'harness-fixture-ping (lambda (_) (push 'new seen)) :key 'k)
    (harness-emit 'harness-fixture-ping :value 1)
    (should (equal seen '(new)))))

(ert-deftest harness-core-deferred-predicate ()
  ;; Regression: a hand-written wrapper once shadowed the struct predicate
  ;; and called a function that did not exist.
  (should (harness-deferred-p (harness-deferred-new)))
  (should-not (harness-deferred-p 42))
  (should-not (harness-deferred-p nil)))

(ert-deftest harness-core-deferred-resolve ()
  (let ((d (harness-deferred-new))
        (got nil))
    (harness-deferred-then d (lambda (value) (setq got value)))
    (harness-deferred-resolve d 3)
    (should (equal got 3))
    (should (harness-deferred-resolved-p d))))

(ert-deftest harness-core-deferred-chaining ()
  (let* ((d (harness-deferred-new))
         (chained (harness-deferred-then d (lambda (value) (* value 2))))
         (got nil))
    (harness-deferred-then chained (lambda (value) (setq got value)))
    (harness-deferred-resolve d 21)
    (should (equal got 42))))

(ert-deftest harness-core-deferred-adopts-returned-deferred ()
  (let* ((d (harness-deferred-new))
         (inner (harness-deferred-new))
         (chained (harness-deferred-then d (lambda (_) inner)))
         (got nil))
    (harness-deferred-then chained (lambda (value) (setq got value)))
    (harness-deferred-resolve d 'ignored)
    (should (harness-deferred-pending-p chained))
    (harness-deferred-resolve inner 'inner-value)
    (should (equal got 'inner-value))))

(ert-deftest harness-core-deferred-reject-and-error-handler ()
  (let ((d (harness-deferred-new))
        (error-seen nil))
    (harness-deferred-then d #'ignore
                           (lambda (err) (setq error-seen err)))
    (harness-deferred-reject d '(failure . "why"))
    (should (equal error-seen '(failure . "why")))))

(ert-deftest harness-core-deferred-cancel ()
  (let* ((d (harness-deferred-new))
         (cancelled nil)
         (error-seen nil))
    (harness-deferred-on-cancel d (lambda () (setq cancelled t)))
    (harness-deferred-then d #'ignore (lambda (err) (setq error-seen err)))
    (harness-deferred-cancel d)
    (should cancelled)
    (should (eq (car error-seen) 'harness-cancelled))
    (should (harness-deferred-rejected-p d))))

(ert-deftest harness-core-deferred-all ()
  (let* ((a (harness-deferred-new))
         (b (harness-deferred-new))
         (all (harness-deferred-all (list a b)))
         (got nil))
    (harness-deferred-then all (lambda (values) (setq got values)))
    (harness-deferred-resolve a 1)
    (should (harness-deferred-pending-p all))
    (harness-deferred-resolve b 2)
    (should (equal got '(1 2)))))

(ert-deftest harness-core-deferred-settles-once ()
  (let ((d (harness-deferred-new))
        (count 0))
    (harness-deferred-then d (lambda (_) (cl-incf count)))
    (harness-deferred-resolve d 1)
    (harness-deferred-resolve d 2)
    (harness-deferred-reject d '(err . "no"))
    (should (= count 1))
    (should (equal (harness-deferred-value d) 1))))

(ert-deftest harness-core-uuid-unique-and-shaped ()
  (let ((a (harness-uuid))
        (b (harness-uuid)))
    (should-not (equal a b))
    (should (string-match-p "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}\\'" a))))

(ert-deftest harness-core-iso-time ()
  (should (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}Z\\'"
                          (harness-iso-time))))

(ert-deftest harness-core-batch-coalesces ()
  (let ((calls 0))
    (harness-batch 'test-key 0.01 (lambda () (cl-incf calls)))
    (harness-batch 'test-key 0.01 (lambda () (cl-incf calls)))
    (should (= calls 0))
    (sit-for 0.05)
    (should (= calls 1))))

(ert-deftest harness-core-budget-run-stops-at-deadline ()
  (let ((iterations 0))
    (harness-budget-run
     0.02
     (lambda ()
       (cl-incf iterations)
       (sit-for 0.005)
       t))
    (should (>= iterations 1))
    (should (< iterations 1000))))

(ert-deftest harness-json-serialize-is-multibyte ()
  ;; `json-serialize' returns unibyte UTF-8 bytes; inserting that into a
  ;; buffer yields raw-byte characters.  The helper returns text.
  (let* ((text "em\u2014dash \u2026 \u65e5\u672c\u8a9e \U0001F389")
         (json (harness-json-serialize (list :text text))))
    (should (multibyte-string-p json))
    (should (equal (plist-get (json-parse-string json :object-type 'plist) :text)
                   text))
    (should (not (multibyte-string-p (json-serialize (list :text text)))))
    ;; A plist argument and explicit options both work (json-serialize
    ;; rejects an explicit nil OPTIONS).
    (should (equal (harness-json-serialize '(:path "x.txt"))
                   "{\"path\":\"x.txt\"}"))
    (should (equal (harness-json-serialize '(:a :false) :false-object :false)
                   "{\"a\":false}"))))

(provide 'harness-core-test)
;;; harness-core-test.el ends here
