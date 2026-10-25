;;; harness-mcp-test.el --- The MCP host: servers that run in the session's sandbox  -*- lexical-binding: t; -*-

;;; Commentary:

;; lisp/modules/harness-mcp.el starts tool servers as processes, in the
;; sandbox the session has, and calls them in the Model Context
;; Protocol.  The server here is test/fixtures/harness-mcp-fake-server.el,
;; an `emacs --batch' that serves tools which say, touch, wait, die and
;; announce.  The suites that run it in the real sandbox probe that bwrap
;; can start, and skip when it cannot.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-mcp-protocol)

(defvar harness-mcp-idle-seconds)
(declare-function harness-mcp-define-server "harness-mcp")
(declare-function harness-mcp-call "harness-mcp")
(declare-function harness-mcp-call-tool "harness-mcp")
(declare-function harness-mcp-tools "harness-mcp")
(declare-function harness-mcp-stop "harness-mcp")
(declare-function harness-mcp-status "harness-mcp")
(declare-function harness-mcp-attach "harness-mcp")
(declare-function harness-mcp-detach "harness-mcp")
(declare-function harness-mcp-receive "harness-mcp")
(declare-function harness-mcp--stop-idle "harness-mcp")
(declare-function harness-sandbox-detect "harness-sandbox")
(declare-function harness-tools-shell-wrap-profile "harness-tools-shell")

(defconst harness-mcp-test--lisp (expand-file-name "lisp/" harness-test-root)
  "The harness's Lisp, which the server loads from.")

(defconst harness-mcp-test--fixtures (file-name-directory (harness-test-fixture "harness-mcp-fake-server.el"))
  "Where the fake server lives.")

(defvar harness-mcp-test--readable nil
  "More directories the fake server's sandbox shows read-only.")

(defvar harness-mcp-test--writable nil
  "More directories the fake server's sandbox shows read-write.")

(defvar harness-mcp-test--command nil
  "The program of the fake server, a function of the call's context, or nil for the real one.")

(defun harness-mcp-test--emacs ()
  "Return the Emacs the fake server runs in."
  (expand-file-name invocation-name invocation-directory))

(defun harness-mcp-test--default-command (_ctx)
  "Return the command line of the fake server."
  (list (harness-mcp-test--emacs) "--batch" "-Q" "-L" harness-mcp-test--lisp
        "-l" (expand-file-name "harness-mcp-fake-server.el" harness-mcp-test--fixtures)
        "-f" "harness-mcp-fake-main"))

(defun harness-mcp-test--profile (ctx)
  "Return the sandbox profile of the fake server for a call under CTX."
  (let ((cwd (plist-get ctx :cwd)))
    (list :cwd cwd
          :writable (cons cwd harness-mcp-test--writable)
          :readable (append (list harness-mcp-test--lisp harness-mcp-test--fixtures)
                            harness-mcp-test--readable))))

(defun harness-mcp-test--declare (&rest keys)
  "Declare the fake server `fake', with KEYS besides the usual."
  (apply #'harness-mcp-define-server 'fake
         :title "Fake"
         :command (lambda (ctx) (funcall (or harness-mcp-test--command #'harness-mcp-test--default-command) ctx))
         :profile #'harness-mcp-test--profile
         keys))

(defmacro harness-mcp-test-with (modules &rest body)
  "Run BODY with the host loaded, the modules MODULES too, and a session directory `dir'.
`ctx' is the context of a call in session \"s1\" there.  Whatever BODY
started is stopped."
  (declare (indent 1))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (require 'harness-tools-shell)
     (dolist (m (append '(project config mcp) ',modules))
       (harness-test-load-module m))
     (let* ((dir (harness-test-temp-dir))
            (ctx (list :session-id "s1" :cwd dir :call-id "c1"))
            (harness-mcp-test--readable nil)
            (harness-mcp-test--writable nil)
            (harness-mcp-test--command nil))
       (ignore ctx)
       (harness-mcp-test--declare)
       (unwind-protect (progn ,@body)
         (harness-mcp-stop)
         (ignore-errors (delete-directory dir t))))))

(defun harness-mcp-test--text (server tool args ctx &rest keys)
  "Call TOOL of SERVER with ARGS under CTX, KEYS as `harness-mcp-call' takes; return its text."
  (harness-mcp-result-text (harness-test-await (apply #'harness-mcp-call server tool args :ctx ctx keys) 30)))

(defun harness-mcp-test--pid (ctx)
  "Return the process id of the fake server serving CTX."
  (let ((text (harness-mcp-test--text 'fake "env" nil ctx)))
    (and (string-match "pid=\\([0-9]+\\)" text) (string-to-number (match-string 1 text)))))

(defun harness-mcp-test--rejection (promise)
  "Return the message PROMISE is rejected with; fail if it is not."
  (condition-case err
      (progn (harness-test-await promise 30) (ert-fail "The promise was not rejected"))
    (harness-error (harness-error-message err))))

(defun harness-mcp-test--bwrap-works-p ()
  "Non-nil when bwrap can start a command here."
  (and (executable-find "bwrap")
       (let ((dir (harness-test-temp-dir)))
         (unwind-protect
             (progn (harness-sandbox-detect)
                    (and (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend))
                         (eql 0 (plist-get (harness-await
                                            (harness-run-command (harness-call 'sandbox/wrap dir '("true"))
                                                                 :cwd dir :timeout 20))
                                           :exit))))
           (ignore-errors (delete-directory dir t))))))

;;;; Calling a server

(ert-deftest harness-mcp-starts-a-server-and-calls-its-tools ()
  (harness-mcp-test-with ()
    (should (equal "echo: hello" (harness-mcp-test--text 'fake "echo" '(:text "hello") ctx)))
    (let ((pid (harness-mcp-test--pid ctx)))
      (should (integerp pid))
      ;; One process serves the session's calls.
      (should (equal pid (harness-mcp-test--pid ctx)))
      (let ((status (harness-mcp-status)))
        (should (= 1 (length status)))
        (should (eq 'fake (plist-get (car status) :server)))
        (should (equal "s1" (plist-get (car status) :scope)))
        (should (eq 'ready (plist-get (car status) :state)))
        (should (equal "fake" (plist-get (plist-get (car status) :info) :name)))))))

(ert-deftest harness-mcp-a-session-has-a-server-of-its-own ()
  (harness-mcp-test-with ()
    (let* ((other (list :session-id "s2" :cwd dir :call-id "c2"))
           (one (harness-mcp-test--pid ctx))
           (two (harness-mcp-test--pid other)))
      (should-not (equal one two))
      (should (= 2 (length (harness-mcp-status))))
      (harness-mcp-stop 'fake "s2")
      (should (= 1 (length (harness-mcp-status))))
      (should (equal one (harness-mcp-test--pid ctx))))))

(ert-deftest harness-mcp-text-crosses-the-pipe-whatever-it-holds ()
  (harness-mcp-test-with ()
    (let ((text "one\ntwo\r\nthree ✓ 日本 \"q\" \\ end"))
      (should (equal (concat "echo: " text) (harness-mcp-test--text 'fake "echo" (list :text text) ctx))))
    (should (= 2000000 (length (harness-mcp-test--text 'fake "big" '(:n 2000000) ctx))))))

(ert-deftest harness-mcp-the-tool-is-told-the-call-it-serves ()
  (harness-mcp-test-with ()
    (let ((context (car (read-from-string
                         (harness-mcp-test--text 'fake "context" nil
                                                 (list :session-id "s1" :cwd dir :call-id "call-9" :host nil))))))
      (should (equal "s1" (plist-get context :sessionId)))
      (should (equal dir (plist-get context :cwd)))
      (should (equal "call-9" (plist-get context :callId))))))

(ert-deftest harness-mcp-a-tool-that-fails-says-so-in-its-result ()
  (harness-mcp-test-with ()
    (let ((result (harness-test-await (harness-mcp-call 'fake "fail" nil :ctx ctx) 30)))
      (should (harness-mcp-result-error-p result))
      (should (string-search "Deliberate failure" (harness-mcp-result-text result))))
    ;; An unknown tool is an error of the protocol, and a rejection here.
    (should (string-search "Unknown tool: nope"
                           (harness-mcp-test--rejection (harness-mcp-call 'fake "nope" nil :ctx ctx))))
    ;; The server goes on.
    (should (equal "echo: still" (harness-mcp-test--text 'fake "echo" '(:text "still") ctx)))))

(ert-deftest harness-mcp-call-tool-brings-a-result-back-as-a-tool-result ()
  (harness-mcp-test-with ()
    (let ((result (harness-test-await (harness-mcp-call-tool 'fake "result" nil ctx) 30)))
      (should (equal "with extras" (plist-get result :content)))
      (should-not (plist-get result :is-error))
      (should (equal "/a/path" (plist-get (car (plist-get result :attachments)) :path)))
      (should (equal 0 (plist-get (plist-get result :meta) :exit)))
      (should (equal "fake" (plist-get (plist-get result :meta) :mcp)))
      (should-not (plist-get (plist-get result :meta) :sandboxed)))
    (let ((result (harness-test-await (harness-mcp-call-tool 'fake "fail" nil ctx) 30)))
      (should (plist-get result :is-error)))
    ;; A host that cannot call is still a result, never a rejection.
    (let ((result (harness-test-await (harness-mcp-call-tool 'nobody "x" nil ctx) 30)))
      (should (plist-get result :is-error))
      (should (string-search "No MCP server nobody" (plist-get result :content))))))

(ert-deftest harness-mcp-lists-the-tools-of-a-server ()
  (harness-mcp-test-with ()
    (let ((names (mapcar (lambda (tool) (plist-get tool :name))
                         (harness-test-await (harness-mcp-tools 'fake ctx) 30))))
      (should (member "echo" names))
      (should (member "read" names)))))

(ert-deftest harness-mcp-what-a-tool-prints-is-not-the-protocol ()
  (harness-mcp-test-with ()
    (should (equal "quiet" (harness-mcp-test--text 'fake "noise" nil ctx)))
    (should (equal "echo: after" (harness-mcp-test--text 'fake "echo" '(:text "after") ctx)))))

(ert-deftest harness-mcp-a-tool-may-answer-later ()
  (harness-mcp-test-with ()
    (should (equal "done later" (harness-mcp-test--text 'fake "later" '(:seconds 0.3) ctx)))))

(ert-deftest harness-mcp-progress-goes-to-the-callers-report ()
  (harness-mcp-test-with ()
    (let ((reports nil))
      (should (equal "ok" (harness-mcp-test--text 'fake "progress" nil ctx
                                                  :report (lambda (text) (push text reports)))))
      (should (equal '("half way" "done") (reverse reports))))))

;;;; Order and time

(ert-deftest harness-mcp-calls-to-a-serial-server-go-one-at-a-time ()
  (harness-mcp-test-with ()
    ;; Warm, so the process start is not counted below.
    (harness-mcp-test--text 'fake "echo" '(:text "warm") ctx)
    (let* ((slow (harness-mcp-call 'fake "sleep" '(:seconds 0.6) :ctx ctx))
           ;; A timeout of its own, shorter than the sleep it waits behind:
           ;; it runs from when the call is sent, not from when it was made.
           (quick (harness-mcp-call 'fake "echo" '(:text "second") :ctx ctx :timeout 0.5)))
      (should (equal "slept" (harness-mcp-result-text (harness-test-await slow 30))))
      (should (equal "echo: second" (harness-mcp-result-text (harness-test-await quick 30)))))))

(ert-deftest harness-mcp-a-call-that-takes-too-long-ends-the-server ()
  (harness-mcp-test-with ()
    (let ((pid (harness-mcp-test--pid ctx))
          (rejection (harness-mcp-test--rejection
                      (harness-mcp-call 'fake "sleep" '(:seconds 30) :ctx ctx :timeout 0.4))))
      (should (string-search "did not answer" rejection))
      (should (string-search "0.4" rejection))
      ;; Nothing is left running, and the next call starts a new process.
      (should (null (harness-mcp-status)))
      (let ((new (harness-mcp-test--pid ctx)))
        (should (integerp new))
        (should-not (equal pid new))))))

(ert-deftest harness-mcp-a-server-that-dies-fails-the-call-it-was-on-and-restarts ()
  (harness-mcp-test-with ()
    (let ((pid (harness-mcp-test--pid ctx))
          (rejection (harness-mcp-test--rejection (harness-mcp-call 'fake "crash" nil :ctx ctx))))
      (should (string-search "exited (3)" rejection))
      (let ((new (harness-mcp-test--pid ctx)))
        (should (integerp new))
        (should-not (equal pid new))))))

(ert-deftest harness-mcp-calls-waiting-behind-a-dead-server-start-a-new-one ()
  (harness-mcp-test-with ()
    (harness-mcp-test--text 'fake "echo" '(:text "warm") ctx)
    (let* ((crash (harness-mcp-call 'fake "crash" nil :ctx ctx))
           (after (harness-mcp-call 'fake "echo" '(:text "survives") :ctx ctx)))
      (should (string-search "exited" (harness-mcp-test--rejection crash)))
      (should (equal "echo: survives" (harness-mcp-result-text (harness-test-await after 30)))))))

(ert-deftest harness-mcp-a-server-that-will-not-start-fails-its-calls-once ()
  (harness-mcp-test-with ()
    (let ((harness-mcp-test--command (lambda (_ctx) (list (harness-mcp-test--emacs) "--batch" "-Q" "--eval" "(kill-emacs 7)"))))
      (let ((a (harness-mcp-call 'fake "echo" nil :ctx ctx))
            (b (harness-mcp-call 'fake "echo" nil :ctx ctx)))
        (should (string-search "did not start" (harness-mcp-test--rejection a)))
        (should (string-search "did not start" (harness-mcp-test--rejection b)))
        ;; It is not tried again and again.
        (sleep-for 0.3)
        (should (null (harness-mcp-status)))
        (should (null (gethash (cons 'fake "s1") harness-mcp--queues)))))
    (let ((harness-mcp-test--command (lambda (_ctx) (list "/nonexistent/program"))))
      (should (string-search "could not start"
                             (harness-mcp-test--rejection (harness-mcp-call 'fake "echo" nil :ctx ctx)))))))

;;;; Lifetime

(ert-deftest harness-mcp-stops-a-server-that-has-been-idle ()
  (harness-mcp-test-with ()
    (harness-mcp-test--declare :idle 0.3)
    (let ((pid (harness-mcp-test--pid ctx)))
      (harness-mcp--stop-idle)
      (should (= 1 (length (harness-mcp-status))))
      (sleep-for 0.5)
      (harness-mcp--stop-idle)
      (should (null (harness-mcp-status)))
      (should-not (equal pid (harness-mcp-test--pid ctx))))))

(ert-deftest harness-mcp-stops-a-sessions-server-when-the-session-is-deleted ()
  (harness-mcp-test-with ()
    (harness-mcp-test--pid ctx)
    (should (= 1 (length (harness-mcp-status))))
    (harness-emit 'session/deleted "other")
    (should (= 1 (length (harness-mcp-status))))
    (harness-emit 'session/deleted "s1")
    (should (null (harness-mcp-status)))))

(ert-deftest harness-mcp-a-changed-sandbox-starts-a-new-process-once-the-old-one-is-idle ()
  (harness-mcp-test-with ()
    (let* ((extra (harness-test-temp-dir))
           (first (harness-mcp-test--pid ctx)))
      (unwind-protect
          (progn
            (should (equal first (harness-mcp-test--pid ctx)))
            ;; A directory granted to the session: the mounts change.
            (let* ((harness-mcp-test--readable (list extra))
                   (slow (harness-mcp-call 'fake "sleep" '(:seconds 0.3) :ctx ctx))
                   (later (harness-mcp-call 'fake "env" nil :ctx ctx)))
              (should (equal "slept" (harness-mcp-result-text (harness-test-await slow 30))))
              (let ((new (harness-mcp-result-text (harness-test-await later 30))))
                (should (string-match "pid=\\([0-9]+\\)" new))
                (should-not (equal first (string-to-number (match-string 1 new)))))))
        (delete-directory extra t)))))

(ert-deftest harness-mcp-stopping-the-host-stops-its-servers ()
  (harness-mcp-test-with ()
    (harness-mcp-test--pid ctx)
    (should (= 1 (harness-mcp-stop)))
    (should (null (harness-mcp-status)))
    (should (= 0 (harness-mcp-stop)))))

;;;; What a server may announce

(ert-deftest harness-mcp-passes-on-the-events-a-server-may-announce-and-no-others ()
  (harness-mcp-test-with ()
    (harness-mcp-test--declare :events '(tools/file-written))
    (let ((seen nil))
      (harness-on 'tools/file-written (lambda (&rest args) (push args seen)))
      (harness-on 'session/deleted (lambda (&rest args) (push (cons 'deleted args) seen)))
      (harness-mcp-test--text 'fake "announce" '(:event "tools/file-written") ctx)
      (harness-mcp-test--text 'fake "announce" '(:event "session/deleted") ctx)
      ;; The second is the harness's own event, which no server may emit.
      (harness-mcp-test--text 'fake "echo" '(:text "flush") ctx)
      (should (equal '(("an-argument")) seen)))))

;;;; Servers that are not started here

(defun harness-mcp-test--external-server ()
  "Return a server, in this process, that stands for the other end of a transport."
  (harness-mcp-make-server
   :name "lent" :version "1"
   :tools (list (harness-mcp-make-tool :name "echo" :schema '(:type "object")
                                       :handler (lambda (args _ctx) (format "lent: %s" (plist-get args :text)))))))

(ert-deftest harness-mcp-calls-a-server-the-other-end-of-a-transport-provides ()
  (harness-mcp-test-with ()
    (harness-mcp-define-server 'lent :title "Lent" :external t)
    ;; Nothing attached yet.
    (should (string-search "No Lent is attached"
                           (harness-mcp-test--rejection (harness-mcp-call 'lent "echo" nil :ctx ctx))))
    (let* ((server (harness-mcp-test--external-server))
           (conn nil))
      (setq conn (harness-mcp-attach
                  'lent
                  (lambda (message)
                    ;; The other end answers later, from the command loop.
                    (run-at-time 0 nil
                                 (lambda ()
                                   (when-let* ((response (harness-mcp-serve server message)))
                                     (harness-mcp-receive conn response)))))))
      (should (equal "lent: hi" (harness-mcp-test--text 'lent "echo" '(:text "hi") ctx)))
      (let ((status (car (harness-mcp-status))))
        (should (eq 'lent (plist-get status :server)))
        (should-not (plist-get status :pid))
        (should-not (plist-get status :sandboxed)))
      ;; The transport goes away: what waits on it fails, and so does the next call.
      (let ((hung (progn (setq server (harness-mcp-make-server
                                       :name "lent"
                                       :tools (list (harness-mcp-make-tool
                                                     :name "echo" :schema '(:type "object")
                                                     :handler (lambda (&rest _) (harness-make-promise))))))
                         (harness-mcp-call 'lent "echo" nil :ctx ctx))))
        (harness-mcp-detach conn "the client left")
        (should (string-search "the client left" (harness-mcp-test--rejection hung)))
        (should (string-search "No Lent is attached"
                               (harness-mcp-test--rejection (harness-mcp-call 'lent "echo" nil :ctx ctx))))))))

(ert-deftest harness-mcp-only-an-external-server-takes-a-transport ()
  (harness-mcp-test-with ()
    (should-error (harness-mcp-attach 'fake #'ignore) :type 'error)))

;;;; The sandbox

(ert-deftest harness-mcp-refuses-to-run-a-server-unconfined-when-the-sandbox-is-required ()
  (harness-mcp-test-with ()
    (harness-register-method 'sandbox/wrap
                             (lambda (_cwd _command &rest _opts)
                               (signal 'error (list "harness-sandbox-policy is `required' but no backend is available"))))
    (should (string-search "required"
                           (harness-mcp-test--rejection (harness-mcp-call 'fake "echo" nil :ctx ctx))))
    (should (null (harness-mcp-status)))))

(ert-deftest harness-mcp-hands-the-session-profile-to-the-sandbox ()
  (harness-mcp-test-with ()
    (let ((wrapped nil)
          (extra (harness-test-temp-dir)))
      (unwind-protect
          (progn
            (harness-register-method 'sandbox/wrap
                                     (lambda (cwd command &rest opts)
                                       (push (list cwd opts) wrapped)
                                       command))
            (let ((harness-mcp-test--readable (list extra))
                  (harness-mcp-test--writable (list "/granted")))
              (harness-mcp-test--text 'fake "echo" '(:text "x") ctx))
            (let ((call (car wrapped)))
              (should (equal dir (car call)))
              (should (member extra (plist-get (cadr call) :readable)))
              (should (member harness-mcp-test--lisp (plist-get (cadr call) :readable)))
              (should (member dir (plist-get (cadr call) :writable)))
              (should (member "/granted" (plist-get (cadr call) :writable)))))
        (delete-directory extra t)))))

(ert-deftest harness-mcp-a-server-in-the-real-sandbox-reaches-only-what-the-session-may ()
  "The server's tools are the file tools' stand-in: whatever the permission
chain decided, the kernel decides what the process can touch."
  (harness-mcp-test-with (sandbox)
    (skip-unless (harness-mcp-test--bwrap-works-p))
    (let* ((outside (harness-test-temp-dir))
           (secret (expand-file-name "secret.txt" outside))
           (victim (expand-file-name "victim/" outside))
           (granted (harness-test-temp-dir))
           (inside (expand-file-name "inside.txt" dir)))
      (unwind-protect
          (progn
            (with-temp-file secret (insert "do not read me"))
            (make-directory victim)
            (with-temp-file (expand-file-name "precious" victim) (insert "do not delete me"))
            (with-temp-file inside (insert "fine to read"))
            (with-temp-file (expand-file-name "granted.txt" granted) (insert "granted"))
            ;; The server runs in the sandbox, and says so.
            (should (string-match-p "sandbox=bwrap" (harness-mcp-test--text 'fake "env" nil ctx)))
            (should (plist-get (car (harness-mcp-status)) :sandboxed))
            ;; What the session may touch works.
            (should (equal "fine to read" (harness-mcp-test--text 'fake "read" (list :path inside) ctx)))
            (should (equal "written" (harness-mcp-test--text 'fake "write" (list :path (expand-file-name "new.txt" dir) :text "w") ctx)))
            (should (file-exists-p (expand-file-name "new.txt" dir)))
            ;; What it may not touch fails at the kernel, in the server's own
            ;; call: the file is not there for it to read, whatever the tool is asked.
            (let ((result (harness-test-await (harness-mcp-call 'fake "read" (list :path secret) :ctx ctx) 30)))
              (should (harness-mcp-result-error-p result))
              (should-not (string-search "do not read me" (harness-mcp-result-text result))))
            (should (harness-mcp-result-error-p
                     (harness-test-await (harness-mcp-call 'fake "write" (list :path (expand-file-name "evil.txt" outside) :text "x") :ctx ctx) 30)))
            (should-not (file-exists-p (expand-file-name "evil.txt" outside)))
            (harness-mcp-test--text 'fake "delete" (list :path victim) ctx)
            (should (file-exists-p (expand-file-name "precious" victim)))
            ;; A directory granted to the session is another process, which sees it.
            (let ((harness-mcp-test--writable (list granted)))
              (should (equal "granted" (harness-mcp-test--text 'fake "read" (list :path (expand-file-name "granted.txt" granted)) ctx)))
              (should (equal "written" (harness-mcp-test--text 'fake "write" (list :path (expand-file-name "g2.txt" granted) :text "g") ctx)))
              (should (file-exists-p (expand-file-name "g2.txt" granted)))))
        (ignore-errors (delete-directory outside t))
        (ignore-errors (delete-directory granted t))))))

(provide 'harness-mcp-test)
;;; harness-mcp-test.el ends here
