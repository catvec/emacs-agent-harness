;;; harness-sandbox-test.el --- Tests for process confinement -*- lexical-binding: t; -*-

;;; Commentary:

;; The argument construction is checked directly, the failure modes are
;; checked with the backend forced to `none', and the real bubblewrap path
;; is exercised end to end when this machine can run it.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-sandbox)
(require 'harness-test-helpers)

(harness-module-load 'harness-sandbox)

(defvar harness-sandbox-test--log nil)

(defmacro harness-sandbox-test--with-backend (backend &rest body)
  "Run BODY with the sandbox backend forced to BACKEND."
  (declare (indent 1))
  `(let ((harness-sandbox--backend ,backend)
         (harness-sandbox--warned nil))
     ,@body))

(defun harness-sandbox-test--has-backend-p (backend)
  "Return non-nil when BACKEND works on this machine."
  (harness-sandbox-backend-usable-p backend))

;;; Argument construction

(ert-deftest harness-sandbox-bwrap-args-contain-the-jail ()
  (harness-sandbox-test--with-backend 'bwrap
    (let* ((policy (harness-sandbox-policy))
           (wrapped (harness-sandbox-wrap "echo" '("hi") "/tmp" policy))
           (args (plist-get wrapped :args)))
      (should (equal (plist-get wrapped :program) "bwrap"))
      (should (plist-get wrapped :confined))
      (should (member "--ro-bind" args))
      (should (member "--proc" args))
      (should (member "--dev" args))
      (should (member "--tmpfs" args))
      ;; A fresh tmpfs is HOME and TMPDIR; the real home is never mounted.
      (should (equal (cadr (member "--tmpfs" args)) "/tmp"))
      (let ((pos (cl-position "--setenv" args :test #'equal)))
        (should pos)
        (should (equal (nth (1+ pos) args) "HOME"))
        (should (equal (nth (+ 2 pos) args) "/tmp")))
      (should-not (member (or (getenv "HOME") "") args))
      ;; /etc is not mounted wholesale.
      (should-not (member "/etc" args))
      ;; The cwd is bound read-write and made the working directory.
      (let ((arguments (append args nil)))
        (should (cl-search '("--bind" "/tmp" "/tmp") arguments :test #'equal))
        (should (cl-search '("--chdir" "/tmp") arguments :test #'equal)))
      (should (member "--unshare-pid" args))
      (should (member "--unshare-ipc" args))
      (should (member "--unshare-uts" args))
      (should (member "--die-with-parent" args))
      (should (member "--new-session" args))
      ;; Network is allowed by default.
      (should-not (member "--unshare-net" args))
      ;; The command follows the -- separator.
      (let ((separator (cl-position "--" args :test #'equal)))
        (should separator)
        (should (equal (nth (1+ separator) args) "echo"))
        (should (equal (nth (+ 2 separator) args) "hi"))))))

(ert-deftest harness-sandbox-bwrap-network-can-be-unshared ()
  (harness-sandbox-test--with-backend 'bwrap
    (let* ((policy (harness-sandbox-policy :network nil))
           (wrapped (harness-sandbox-wrap "echo" nil "/tmp" policy)))
      (should (member "--unshare-net" (plist-get wrapped :args))))))

(ert-deftest harness-sandbox-bwrap-extra-paths ()
  (harness-sandbox-test--with-backend 'bwrap
    (let* ((extra (make-temp-file "harness-sandbox-extra-" t))
           (policy (harness-sandbox-policy :writable (list extra) :read-only (list "/opt")))
           (args (plist-get (harness-sandbox-wrap "echo" nil "/tmp" policy) :args)))
      (should (member extra args))
      (should (member "/opt" args))
      ;; Read-only extra path uses --ro-bind, writable uses --bind.
      (let ((ro-pos (cl-position "/opt" args :test #'equal))
            (rw-pos (cl-position extra args :test #'equal)))
        (should (equal (nth (1- ro-pos) args) "--ro-bind"))
        (should (equal (nth (1- rw-pos) args) "--bind")))
      (delete-directory extra t))))

(ert-deftest harness-sandbox-systemd-args ()
  (harness-sandbox-test--with-backend 'systemd-run
    (let* ((wrapped (harness-sandbox-wrap "echo" '("hi") "/tmp" (harness-sandbox-policy)))
           (args (plist-get wrapped :args)))
      (should (equal (plist-get wrapped :program) "systemd-run"))
      (should (plist-get wrapped :confined))
      (should (member "--user" args))
      (should (member "--scope" args))
      (should (member "--property=ProtectSystem=strict" args))
      (should (member "--property=ProtectHome=yes" args))
      (should (member "--property=PrivateDevices=yes" args))
      (should (member "--setenv=HOME=/tmp" args))
      (should (member "--property=ReadWritePaths=/tmp" args))
      (should (member "--property=WorkingDirectory=/tmp" args))
      ;; The command comes last.
      (should (equal (car (last args 2)) "echo"))
      (should (equal (car (last args)) "hi")))))

(ert-deftest harness-sandbox-required-without-backend-fails-closed ()
  (harness-sandbox-test--with-backend 'none
    (should-error
     (harness-sandbox-wrap "echo" nil "/tmp" (harness-sandbox-policy :mode 'required))
     :type 'harness-sandbox-error)))

(ert-deftest harness-sandbox-preferred-without-backend-runs-direct-and-warns ()
  (harness-sandbox-test--with-backend 'none
    (let* ((warnings nil)
           (wrapped (cl-letf (((symbol-function 'display-warning)
                               (lambda (_type message &rest _args)
                                 (push message warnings))))
                      (harness-sandbox-wrap "echo" '("hi") "/tmp"
                                            (harness-sandbox-policy :mode 'preferred)))))
      (should (equal (plist-get wrapped :program) "echo"))
      (should-not (plist-get wrapped :confined))
      (should (= (length warnings) 1))
      (should (string-match-p "UNCONFINED" (car warnings))))))

(ert-deftest harness-sandbox-none-mode-never-wraps ()
  (harness-sandbox-test--with-backend 'bwrap
    (let ((wrapped (harness-sandbox-wrap "echo" '("hi") "/tmp"
                                         (harness-sandbox-policy :mode 'none))))
      (should (equal (plist-get wrapped :program) "echo"))
      (should-not (plist-get wrapped :confined)))))

;;; Spawning

(ert-deftest harness-sandbox-spawn-direct ()
  (harness-sandbox-test--with-backend 'none
    (let* ((output "")
           (finished nil)
           (spawned (harness-sandbox-spawn
                     :name "harness-sandbox-test-direct"
                     :command "/bin/sh"
                     :args '("-c" "echo hello-sandbox")
                     :cwd temporary-file-directory
                     :policy (harness-sandbox-policy :mode 'none)
                     :filter (lambda (_process chunk) (setq output (concat output chunk)))
                     :sentinel (lambda (_process _event) (setq finished t))))
           (process (harness-sandbox-process-process spawned)))
      (should (harness-test-wait-for (lambda () finished)))
      (should (string-match-p "hello-sandbox" output))
      (should-not (harness-sandbox-process-confined spawned)))))

(ert-deftest harness-sandbox-spawn-sync-captures-output ()
  (harness-sandbox-test--with-backend 'none
    (let ((result (harness-sandbox-spawn-sync
                   "/bin/sh" '("-c" "printf out; printf err >&2")
                   :cwd temporary-file-directory
                   :policy (harness-sandbox-policy :mode 'none)
                   :timeout 10)))
      (should (equal (car result) 0))
      ;; stderr goes to the same pipe here.
      (should (string-match-p "out" (cdr result)))
      (should (string-match-p "err" (cdr result))))))

(ert-deftest harness-sandbox-spawn-sync-timeout ()
  (harness-sandbox-test--with-backend 'none
    (let ((result (harness-sandbox-spawn-sync
                   "/bin/sh" '("-c" "sleep 30")
                   :cwd temporary-file-directory
                   :policy (harness-sandbox-policy :mode 'none)
                   :timeout 0.2)))
      (should (eq (car result) 'timeout)))))

(ert-deftest harness-sandbox-spawn-rejects-missing-cwd ()
  (harness-sandbox-test--with-backend 'none
    (should-error
     (harness-sandbox-spawn :command "/bin/true"
                            :cwd "/tmp/harness-sandbox-does-not-exist-12345"
                            :policy (harness-sandbox-policy :mode 'none))
     :type 'harness-sandbox-error)))

;;; Real bubblewrap

(ert-deftest harness-sandbox-bwrap-real-confinement ()
  (skip-unless (harness-sandbox-test--has-backend-p 'bwrap))
  (harness-sandbox-test--with-backend 'bwrap
    (let* ((cwd (make-temp-file "harness-sandbox-real-" t))
           (result (harness-sandbox-spawn-sync
                    "/bin/sh"
                    '("-c" "echo cwd-ok > inside.txt; cat /etc/passwd > /dev/null 2>&1 && echo etc-readable; test -e /etc/hostname && echo etc-broad || echo etc-minimal; touch /usr/should-not-exist 2>/dev/null && echo usr-writable || echo usr-read-only; echo home=$HOME; touch $HOME/x && echo home-writable || echo home-not-writable; ls /home >/dev/null 2>&1 && echo home-visible || echo home-hidden; test -e /etc/shadow && echo shadow-leak || echo no-shadow")
                    :cwd cwd
                    :policy (harness-sandbox-policy)
                    :timeout 20)))
      (unwind-protect
          (progn
            (should (equal (car result) 0))
            (should (file-exists-p (expand-file-name "inside.txt" cwd)))
            (should (string-match-p "etc-readable" (cdr result)))
            (should (string-match-p "etc-minimal" (cdr result)))
            (should (string-match-p "usr-read-only" (cdr result)))
            (should (string-match-p "home=/tmp" (cdr result)))
            (should (string-match-p "home-writable" (cdr result)))
            (should (string-match-p "home-hidden" (cdr result)))
            (should (string-match-p "no-shadow" (cdr result))))
        (delete-directory cwd t)))))

(provide 'harness-sandbox-test)
;;; harness-sandbox-test.el ends here
