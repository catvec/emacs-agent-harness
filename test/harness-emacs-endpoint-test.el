;;; harness-emacs-endpoint-test.el --- Tools run in the harness; an Emacs is lent to it  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every tool runs in the harness.  The tools about the user's Emacs
;; reach the Emacs a client lent to the harness (advertised in
;; `initialize'), exactly one of them, and never a client that lends
;; none, such as a phone.  These tests connect in-process clients of
;; both kinds and check who is asked, what they answer, and what the
;; tools make of it.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-model)
(defvar harness-tools-max-output-chars)
(defvar harness-emacs-eval)
(defvar harness-emacs-endpoint--methods)
(defvar harness-emacs-endpoint--evaluating)
(defvar harness-emacs-endpoint--deferred-methods)
(defvar harness-emacs-endpoint--eval-retry)
(declare-function harness-emacs-eval-p "harness-emacs-endpoint" ())
(declare-function harness-emacs-endpoint--eval "harness-emacs-endpoint" (params answer fail))
(declare-function harness-emacs-endpoint--seconds "harness-emacs-endpoint" (value default max))
(declare-function harness-emacs-endpoint-test--defined nil)
(declare-function harness-tools-reason "harness-tools" (err))
(declare-function harness-acp-add-client "harness-acp")
(declare-function harness-acp-client-receive "harness-acp")
(declare-function harness-acp-drop-client "harness-acp")
(declare-function harness-acp-close "harness-acp")
(declare-function harness-acp-request "harness-acp")
(declare-function harness-acp-respond-error "harness-acp")
(declare-function harness-emacs-endpoint-handle "harness-emacs-endpoint")

(defvar harness-emacs-endpoint-test--evaluations 0
  "How many times test code evaluated in this Emacs.")

(defvar harness-emacs-endpoint-test--after nil
  "Set by test code that went on past where it should have been stopped.")

(defvar harness-emacs-endpoint-test--order nil
  "What test evaluations did, newest first.")

(defvar harness-emacs-endpoint-test--inner nil
  "The promise of an evaluation that test code asked for.")

(defun harness-emacs-endpoint-test--allow (_decision next &rest _)
  "Permissive permission filter for the tests."
  (funcall next (list :behavior 'allow)))

(defun harness-emacs-endpoint-test--setup ()
  "Load the tool modules and acp, allow every call, and drop every client.
Each test then connects the clients it is about, and only those."
  (setq harness-acp--server-enabled nil)
  (harness-test-load-module 'acp)
  (harness-test-load-module 'tools)
  (harness-test-load-module 'tools-emacs)
  (harness-test-load-module 'tools-shell)
  (require 'harness-emacs-endpoint)
  (harness-add-filter 'permission/decide #'harness-emacs-endpoint-test--allow 10)
  (dolist (client (copy-sequence harness-acp--clients))
    (harness-acp-drop-client client)))

(defun harness-emacs-endpoint-test--connect (lend)
  "Connect an in-process client; it lends this Emacs when LEND.
Return (CONNECTION . SEEN): SEEN is a cons whose car lists the methods
the harness sent the client, newest first.  A client that lends no
Emacs (a phone, say) answers no request; one that does answers the
harness's requests for its Emacs."
  (let ((conn (harness-acp-connect nil))
        (seen (list nil)))
    (harness-acp-set-handler
     conn
     (lambda (method params respond)
       (push method (car seen))
       (unless (and lend (harness-emacs-endpoint-answer method params respond))
         (when respond (harness-acp-respond-error respond -32601 (format "unhandled %s" method))))))
    (harness-test-await (harness-acp-initialize conn (and lend (harness-emacs-endpoint-client-capabilities))))
    (cons conn seen)))

(defun harness-emacs-endpoint-test--call (name &rest input)
  "Execute tool NAME with INPUT through tools/execute and wait."
  (harness-test-await (harness-call 'tools/execute nil (list :id "c1" :name name :input input)) 20))

(defun harness-emacs-endpoint-test--asked-p (seen)
  "Non-nil when SEEN, from `harness-emacs-endpoint-test--connect', got a tool's request."
  (cl-some (lambda (method) (or (string-prefix-p "_harness/emacs/" method)
                                (equal method "_harness/client/tool")))
           (car seen)))

;;;; Who is asked

(ert-deftest harness-emacs-endpoint-a-client-that-lends-no-emacs-is-never-asked ()
  "With only a phone-like client, the harness has no Emacs to ask: the
tools about the user's Emacs say so at once, the elisp tool evaluates
in the background as always, and the client gets no tool request."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let ((phone (harness-emacs-endpoint-test--connect nil)))
      (unwind-protect
          (progn
            (should-not (harness-call 'emacs/attached))
            (dolist (call '(("emacs_buffers") ("emacs_buffer" :name "*scratch*")
                            ("emacs_describe" :symbol "car") ("emacs_messages")))
              (let ((r (apply #'harness-emacs-endpoint-test--call call)))
                (should (plist-get r :is-error))
                (should (string-prefix-p "No Emacs is attached to the harness" (plist-get r :content)))
                (should (string-search "elisp tool" (plist-get r :content)))))
            ;; The debugging tools point elsewhere: a definition can be
            ;; grepped for; a trace has nothing to stand in for it.
            (dolist (call '(("emacs_find_definition" :symbol "car" "grep")
                            ("emacs_trace" :symbol "car" nil)))
              (let ((r (harness-emacs-endpoint-test--call (nth 0 call) (nth 1 call) (nth 2 call))))
                (should (plist-get r :is-error))
                (should (string-prefix-p "No Emacs is attached to the harness" (plist-get r :content)))
                (if (nth 3 call)
                    (should (string-search (nth 3 call) (plist-get r :content)))
                  (should-not (string-search "elisp tool" (plist-get r :content))))))
            (let ((r (harness-emacs-endpoint-test--call "elisp" :code "(+ 1 2)")))
              (should (equal "=> 3" (plist-get r :content)))
              (should (equal "background" (plist-get (plist-get r :meta) :emacs))))
            ;; No Emacs to ask, and the elisp tool would not evaluate
            ;; in one even if there were: a call that asks is refused
            ;; for that reason first.
            (let ((r (harness-emacs-endpoint-test--call "elisp" :code "(+ 1 2)" :emacs "user")))
              (should (plist-get r :is-error))
              (should (string-search "never evaluates in the user's Emacs" (plist-get r :content)))
              (should (string-search "emacs_* tools" (plist-get r :content))))
            (should-not (harness-emacs-endpoint-test--asked-p (cdr phone))))
        (harness-acp-close (car phone))))))

(ert-deftest harness-emacs-endpoint-the-lending-emacs-answers-beside-a-phone ()
  "A phone and an Emacs connected at once: the Emacs is asked, the phone never."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let* ((emacs (harness-emacs-endpoint-test--connect t))
           (phone (harness-emacs-endpoint-test--connect nil))
           (buffer (generate-new-buffer "harness-endpoint-lent")))
      (unwind-protect
          (progn
            ;; The phone spoke last, yet it lends no Emacs.
            (harness-test-await (harness-acp-request (car phone) "_harness/harness/version" nil))
            (let ((attached (harness-call 'emacs/attached)))
              (should (= 1 (length attached)))
              (should (equal (emacs-pid) (plist-get (car attached) :pid)))
              (should (equal emacs-version (plist-get (car attached) :version))))
            (should (string-search "harness-endpoint-lent"
                                   (plist-get (harness-emacs-endpoint-test--call "emacs_buffers") :content)))
            (should (member "_harness/emacs/buffers" (car (cdr emacs))))
            (should-not (harness-emacs-endpoint-test--asked-p (cdr phone))))
        (kill-buffer buffer)
        (harness-acp-close (car phone))
        (harness-acp-close (car emacs))))))

(ert-deftest harness-emacs-endpoint-exactly-one-emacs-answers ()
  "Two Emacsen lent at once: a request goes to one of them, the most
recently active, never to both.  A broadcast would, for instance, open
the same file in every connected Emacs."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let ((a (harness-emacs-endpoint-test--connect t))
          (b (harness-emacs-endpoint-test--connect t)))
      (unwind-protect
          (progn
            ;; A is where the user is now.
            (harness-test-await (harness-acp-request (car a) "_harness/harness/version" nil))
            (let ((r (harness-emacs-endpoint-test--call "emacs_windows")))
              (should-not (plist-get r :is-error))
              (should (string-search "FRAME" (plist-get r :content))))
            (should (member "_harness/emacs/windows" (car (cdr a))))
            (should-not (member "_harness/emacs/windows" (car (cdr b))))
            ;; Then B: the request follows the user, still to one Emacs.
            (harness-test-await (harness-acp-request (car b) "_harness/harness/version" nil))
            (harness-emacs-endpoint-test--call "emacs_windows")
            (should (member "_harness/emacs/windows" (car (cdr b))))
            (should (= 1 (cl-count "_harness/emacs/windows" (car (cdr a)) :test #'equal))))
        (harness-acp-close (car a))
        (harness-acp-close (car b))))))

(ert-deftest harness-emacs-endpoint-an-unauthenticated-client-lends-nothing ()
  "A client that has not authenticated may advertise an Emacs, but is
not one the harness asks: it could answer for the user's Emacs, and be
shown its buffers, with what it likes."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let* ((sent nil)
           (client (harness-acp-add-client 'test :writer (lambda (_client text) (push text sent))
                                           :remote '(:address "192.0.2.7"))))
      (unwind-protect
          (progn
            (harness-acp-client-receive
             client (harness-json-encode-text
                     (list :jsonrpc "2.0" :id 1 :method "initialize"
                           :params (list :protocolVersion 1
                                         :clientCapabilities (harness-emacs-endpoint-client-capabilities)))))
            (harness-test-wait (lambda () sent) 5 "initialize answer")
            (should-not (harness-call 'emacs/attached))
            (let ((r (harness-emacs-endpoint-test--call "emacs_buffers")))
              (should (string-prefix-p "No Emacs is attached" (plist-get r :content))))
            (should-not (cl-some (lambda (text) (string-search "_harness/emacs/" text)) sent)))
        (harness-acp-drop-client client)))))

(ert-deftest harness-emacs-endpoint-an-emacs-that-leaves-fails-the-call ()
  "An Emacs that disconnects before it answers fails the call, saying so."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let ((conn (harness-acp-connect nil)))
      (harness-test-await (harness-acp-initialize conn (harness-emacs-endpoint-client-capabilities)))
      (harness-acp-set-handler conn (lambda (method &rest _)
                                      (when (string-prefix-p "_harness/emacs/" method)
                                        (run-at-time 0 nil #'harness-acp-close conn))))
      (let ((r (harness-emacs-endpoint-test--call "emacs_buffers")))
        (should (plist-get r :is-error))
        (should (string-prefix-p "The user's Emacs disconnected before it answered." (plist-get r :content)))))))

(defvar harness-ui-connection)
(declare-function harness-ui--advertise "harness-ui")
(declare-function harness-ui--dispatch "harness-ui")

(ert-deftest harness-emacs-endpoint-the-ui-lends-its-emacs-again-after-a-reload ()
  "A connection the UI opened with older code lent nothing; after a
reload the UI advertises its Emacs on it, and its dispatch answers for
that Emacs."
  (harness-emacs-endpoint-test--setup)
  (require 'harness-ui)
  (harness-test-with-temp-state
    (let ((conn (harness-acp-connect nil))
          (buffer (generate-new-buffer "harness-endpoint-reloaded")))
      (unwind-protect
          (progn
            (harness-acp-set-handler conn #'harness-ui--dispatch)
            ;; Older code: ACP's own capabilities only.
            (harness-test-await (harness-acp-initialize conn))
            (should-not (harness-call 'emacs/attached))
            (let ((harness-ui-connection conn))
              (harness-ui--advertise)
              (harness-test-wait (lambda () (harness-call 'emacs/attached)) 5 "the UI's Emacs to be lent"))
            (should (equal (emacs-pid) (plist-get (car (harness-call 'emacs/attached)) :pid)))
            (should (string-search "harness-endpoint-reloaded"
                                   (plist-get (harness-emacs-endpoint-test--call "emacs_buffers") :content))))
        (kill-buffer buffer)
        (harness-acp-close conn)))))

;;;; What the Emacs answers

(ert-deftest harness-emacs-endpoint-answers-data-not-tool-results ()
  "The lent Emacs sends plain data; the tools word it in the harness."
  (require 'harness-emacs-endpoint)
  (let ((buffer (generate-new-buffer "harness-endpoint-data")))
    (unwind-protect
        (progn
          (with-current-buffer buffer (insert "alpha\nbeta\n") (set-buffer-modified-p nil))
          (let ((row (cl-find "harness-endpoint-data" (plist-get (harness-emacs-endpoint-handle "buffers" nil) :buffers)
                              :key (lambda (b) (plist-get b :name)) :test #'equal)))
            (should (equal "fundamental-mode" (plist-get row :mode)))
            (should (eq :false (plist-get row :modified)))
            (should (= 11 (plist-get row :size))))
          (should (equal '(:exists :false) (harness-emacs-endpoint-handle "buffer" '(:name "harness-endpoint-none"))))
          (let ((answer (harness-emacs-endpoint-handle "buffer" '(:name "harness-endpoint-data" :offset 2))))
            (should (equal '("beta") (plist-get answer :lines)))
            (should (= 2 (plist-get answer :first)))
            (should (= 2 (plist-get answer :total))))
          (let ((answer (harness-emacs-endpoint-handle "describe" '(:symbol "car"))))
            (should (eq t (plist-get answer :known)))
            (should (equal "primitive" (plist-get (plist-get answer :function) :kind)))
            (should (string-prefix-p "(car " (plist-get (plist-get answer :function) :signature)))
            (should-not (plist-get answer :variable)))
          (should (eq :false (plist-get (harness-emacs-endpoint-handle "describe" '(:symbol "harness-endpoint-nonesuch-q"))
                                        :known)))
          (let ((answer (harness-emacs-endpoint-handle "definition" '(:symbol "car"))))
            (should (eq t (plist-get answer :known)))
            (should (equal "function" (plist-get answer :type)))
            (should (equal "built-in function" (plist-get answer :kind)))
            (should (eq :false (plist-get answer :advised))))
          (should (eq :false (plist-get (harness-emacs-endpoint-handle "definition" '(:symbol "harness-endpoint-nonesuch-q"))
                                        :known)))
          (let ((answer (harness-emacs-endpoint-handle "trace" '(:action "list"))))
            (should (equal "*trace-output*" (plist-get answer :buffer)))
            (should (integerp (plist-get answer :lines))))
          (should-error (harness-emacs-endpoint-handle "trace" '(:action "eval" :symbol "car")))
          (should-error (harness-emacs-endpoint-handle "shell" nil))
          ;; The one request that evaluates code answers once it has
          ;; run, through `harness-emacs-endpoint-answer' alone (see
          ;; the eval tests below), never as data at once.
          (should-not (assoc "eval" harness-emacs-endpoint--methods))
          (should (assoc "eval" harness-emacs-endpoint--deferred-methods))
          (let ((harness-emacs-eval t))
            (should-error (harness-emacs-endpoint-handle "eval" '(:code "(+ 1 2)")))))
      (kill-buffer buffer))))

(ert-deftest harness-emacs-endpoint-reads-are-bounded ()
  "Nothing big crosses from the user's Emacs: a long buffer is read in
ranges, a long line is cut, and a big value is printed only in part."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let ((conn (harness-test-connect-ui-client))
          (buffer (generate-new-buffer "harness-endpoint-long"))
          (harness-tools-max-output-chars 1500))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (dotimes (i 300) (insert (format "line %03d of the long buffer\n" (1+ i)))))
            (let* ((c (plist-get (harness-emacs-endpoint-test--call "emacs_buffer" :name "harness-endpoint-long") :content))
                   (next (and (string-match "read on with offset \\([0-9]+\\)" c)
                              (string-to-number (match-string 1 c)))))
              (should next)
              (should (< 1 next 300))
              (should (string-search "lines 1-" c))
              (should (< (length c) harness-tools-max-output-chars))
              (let ((c2 (plist-get (harness-emacs-endpoint-test--call "emacs_buffer" :name "harness-endpoint-long"
                                                                      :offset next)
                                   :content)))
                (should (string-prefix-p (format "%6d\tline %03d" next next) c2))))
            ;; One line longer than a whole read is cut, and the read goes on after it.
            (with-current-buffer buffer (erase-buffer) (insert (make-string 5000 ?x) "\nshort\n"))
            (let ((c (plist-get (harness-emacs-endpoint-test--call "emacs_buffer" :name "harness-endpoint-long") :content)))
              (should (string-search "read on with offset 2" c))
              (should (< (length c) harness-tools-max-output-chars)))
            ;; A long list is printed in part by the user's Emacs.
            (defvar harness-emacs-endpoint-test--long (number-sequence 1 100000))
            (let ((c (plist-get (harness-emacs-endpoint-test--call "emacs_describe" :symbol "harness-emacs-endpoint-test--long")
                                :content)))
              (should (string-search "value: (1 2 3" c))
              (should (< (length c) 800))))
        (kill-buffer buffer)
        (harness-acp-close conn)))))

;;;; Evaluating, when the user lets agents

(defun harness-emacs-endpoint-test--eval (code &rest params)
  "Have the lent Emacs evaluate CODE with PARAMS, as emacs_eval asks it.
Return its answer, or (failed MESSAGE) when it refused or ran nothing.
The request reaches the Emacs as a real one does, from a timer, where
quitting is inhibited."
  (condition-case err
      (harness-test-await (harness-call 'emacs/request "eval" (append (list :code code) params)) 20)
    (error (list 'failed (harness-tools-reason err)))))

(defmacro harness-emacs-endpoint-test--with-eval (&rest body)
  "Run BODY with this Emacs lent to the harness, letting agents evaluate in it.
`harness-emacs-eval' is set globally, as the settings page sets it,
and put back after."
  (declare (indent 0))
  (let ((conn (make-symbol "conn")) (old (make-symbol "old")))
    `(progn
       (harness-emacs-endpoint-test--setup)
       (harness-test-with-temp-state
         (let ((,conn (harness-test-connect-ui-client))
               (,old (default-value 'harness-emacs-eval)))
           (setq harness-emacs-endpoint-test--evaluations 0
                 harness-emacs-endpoint-test--after nil
                 harness-emacs-endpoint-test--order nil)
           (setq-default harness-emacs-eval t)
           (unwind-protect (progn ,@body)
             (setq-default harness-emacs-eval ,old)
             (harness-acp-close ,conn)))))))

(ert-deftest harness-emacs-endpoint-eval-is-refused-unless-the-user-lets-agents ()
  "Off, as it is by default, the lent Emacs evaluates nothing, whatever
the harness asks; a buffer's own value does not turn it on."
  (require 'harness-emacs-endpoint)
  (should-not (eval (car (get 'harness-emacs-eval 'standard-value)) t))
  (harness-emacs-endpoint-test--with-eval
    (setq-default harness-emacs-eval nil)
    (let ((r (harness-emacs-endpoint-test--eval "(cl-incf harness-emacs-endpoint-test--evaluations)")))
      (should (eq 'failed (car r)))
      (should (string-search "harness-emacs-eval" (cadr r)))
      (should (string-search "off there" (cadr r))))
    (with-temp-buffer
      (setq-local harness-emacs-eval t)
      (should-not (harness-emacs-eval-p))
      (should (eq 'failed (car (harness-emacs-endpoint-test--eval "(cl-incf harness-emacs-endpoint-test--evaluations)")))))
    (should (= 0 harness-emacs-endpoint-test--evaluations))))

(ert-deftest harness-emacs-endpoint-eval-answers-the-value-output-and-messages ()
  "The code runs here, form by form with lexical binding, and changes
this Emacs; the answer holds its printed value, what it printed and
the messages it logged, each cut at the size the harness names."
  (harness-emacs-endpoint-test--with-eval
    (let ((r (harness-emacs-endpoint-test--eval
              (concat "(cl-incf harness-emacs-endpoint-test--evaluations)\n"
                      "(princ \"printed\")\n"
                      "(message \"said %d\" 42)\n"
                      "(let ((f (let ((x 5)) (lambda () x)))) (list (funcall f) \"two\" 'three))"))))
      (should (equal "(5 \"two\" three)" (plist-get r :value)))
      (should (equal "printed" (plist-get r :output)))
      (should (equal "said 42" (plist-get r :messages)))
      (should-not (plist-get r :error))
      (should-not (plist-get r :stopped))
      (should (numberp (plist-get r :seconds))))
    (should (= 1 harness-emacs-endpoint-test--evaluations))
    (unwind-protect
        (progn
          (harness-emacs-endpoint-test--eval "(defun harness-emacs-endpoint-test--defined () 'here)")
          (should (eq 'here (funcall 'harness-emacs-endpoint-test--defined))))
      (fmakunbound 'harness-emacs-endpoint-test--defined))
    (let ((r (harness-emacs-endpoint-test--eval "(make-string 5000 ?x)" :maxChars 200)))
      (should (< (length (plist-get r :value)) 300)))
    (should-not harness-emacs-endpoint--evaluating)))

(ert-deftest harness-emacs-endpoint-eval-reports-errors-and-refuses-prompts ()
  "An error is part of the answer; the code may not prompt; code that is
missing, too long or does not read runs not at all."
  (harness-emacs-endpoint-test--with-eval
    (let ((r (harness-emacs-endpoint-test--eval "(message \"before\") (error \"Boom %d\" 7)")))
      (should (equal "Boom 7" (plist-get r :error)))
      (should (equal "before" (plist-get r :messages)))
      (should-not (plist-get r :stopped)))
    (dolist (code '("(read-string \"Name: \")" "(y-or-n-p \"Sure? \")"))
      (should (string-search "inhibited" (plist-get (harness-emacs-endpoint-test--eval code) :error))))
    (let ((r (harness-emacs-endpoint-test--eval "(cl-incf harness-emacs-endpoint-test--evaluations) (+ 1")))
      (should (eq 'failed (car r)))
      (should (string-search "does not read" (cadr r))))
    (should (equal '(failed "Missing code") (harness-emacs-endpoint-test--eval "  ")))
    (should (string-search "longer than" (cadr (harness-emacs-endpoint-test--eval
                                                (concat "'" (make-string 100001 ?x))))))
    (should (= 0 harness-emacs-endpoint-test--evaluations))))

(ert-deftest harness-emacs-endpoint-eval-stops-code-that-waits ()
  "Code that waits is stopped once it has waited what it may, by a timer
of the evaluation's own that no `catch' or `with-timeout' in the code
takes for its own; the harness names the time, within a bound."
  (harness-emacs-endpoint-test--with-eval
    (dolist (code '("(sleep-for 5)"
                    "(accept-process-output nil 5)"
                    "(catch 'harness-emacs-endpoint-test--tag (sit-for 5))"
                    "(with-timeout (10 'late) (sleep-for 5))"))
      (setq harness-emacs-endpoint-test--after nil)
      (let* ((start (float-time))
             (r (harness-emacs-endpoint-test--eval
                 (concat "(cl-incf harness-emacs-endpoint-test--evaluations) " code
                         " (setq harness-emacs-endpoint-test--after t)")
                 :timeout 0.3)))
        (should (equal "timeout" (plist-get r :stopped)))
        (should-not (plist-get r :error))
        (should (< (- (float-time) start) 3))
        (should-not harness-emacs-endpoint-test--after)))
    (should (= 4 harness-emacs-endpoint-test--evaluations))
    (should-not harness-emacs-endpoint--evaluating)
    (should (= 2 (harness-emacs-endpoint--seconds nil 2 10)))
    (should (= 2 (harness-emacs-endpoint--seconds -1 2 10)))
    (should (= 0.5 (harness-emacs-endpoint--seconds 0.5 2 10)))
    (should (= 10 (harness-emacs-endpoint--seconds 100 2 10)))))

(ert-deftest harness-emacs-endpoint-eval-stops-at-the-users-next-key ()
  "The user's next key stops the code (input under `while-no-input'
throws to `throw-on-input'), and so does C-g, which quits the code
alone: `quit-flag' is clear after, so nothing else quits."
  (harness-emacs-endpoint-test--with-eval
    (let ((r (harness-emacs-endpoint-test--eval
              "(cl-incf harness-emacs-endpoint-test--evaluations) (throw throw-on-input t) (setq harness-emacs-endpoint-test--after t)")))
      (should (equal "input" (plist-get r :stopped)))
      (should-not harness-emacs-endpoint-test--after))
    (let ((r (harness-emacs-endpoint-test--eval
              "(cl-incf harness-emacs-endpoint-test--evaluations) (signal 'quit nil) (setq harness-emacs-endpoint-test--after t)")))
      (should (equal "quit" (plist-get r :stopped)))
      (should-not harness-emacs-endpoint-test--after)
      (should-not quit-flag))
    ;; C-g can quit the code, though requests arrive where it cannot.
    (should (equal "nil" (plist-get (harness-emacs-endpoint-test--eval "inhibit-quit") :value)))
    (should (= 2 harness-emacs-endpoint-test--evaluations))
    (should-not harness-emacs-endpoint--evaluating)))

(ert-deftest harness-emacs-endpoint-eval-waits-while-the-user-types ()
  "Code never starts while the user is typing: it waits for a pause, and
runs nothing when none comes before the harness stops waiting."
  (harness-emacs-endpoint-test--with-eval
    (let ((checks 0) (start (float-time)))
      (cl-letf (((symbol-function 'harness-emacs-endpoint--input-pending-p)
                 (lambda () (<= (cl-incf checks) 3))))
        (should (equal "1" (plist-get (harness-emacs-endpoint-test--eval
                                       "(cl-incf harness-emacs-endpoint-test--evaluations)")
                                      :value))))
      (should (= 4 checks))
      (should (>= (- (float-time) start) (* 3 harness-emacs-endpoint--eval-retry))))
    (cl-letf (((symbol-function 'harness-emacs-endpoint--input-pending-p) (lambda () t)))
      (let ((r (harness-emacs-endpoint-test--eval "(cl-incf harness-emacs-endpoint-test--evaluations)"
                                                  :deadline (+ (float-time) 0.4) :host (system-name))))
        (should (eq 'failed (car r)))
        (should (string-search "typing" (cadr r)))))
    (should (= 1 harness-emacs-endpoint-test--evaluations))))

(ert-deftest harness-emacs-endpoint-eval-never-starts-once-the-harness-gave-up ()
  "A request read after the harness stopped waiting for it runs nothing.
The deadline is by the harness's clock, so it counts only on the
harness's machine; there it also bounds how long the code may wait."
  (harness-emacs-endpoint-test--with-eval
    (let ((r (harness-emacs-endpoint-test--eval "(cl-incf harness-emacs-endpoint-test--evaluations)"
                                                :deadline (- (float-time) 1) :host (system-name))))
      (should (eq 'failed (car r)))
      (should (string-search "stopped waiting" (cadr r))))
    (should (= 0 harness-emacs-endpoint-test--evaluations))
    (should (equal "1" (plist-get (harness-emacs-endpoint-test--eval
                                   "(cl-incf harness-emacs-endpoint-test--evaluations)"
                                   :deadline (- (float-time) 1) :host "elsewhere.invalid")
                                  :value)))
    (let* ((start (float-time))
           (r (harness-emacs-endpoint-test--eval "(sleep-for 5)" :timeout 5
                                                 :deadline (+ start 0.5) :host (system-name))))
      (should (equal "timeout" (plist-get r :stopped)))
      (should (< (- (float-time) start) 2)))))

(ert-deftest harness-emacs-endpoint-eval-never-nests ()
  "Code that waits lets other requests in, and a second evaluation waits
for the first to end rather than run inside it; one that waits until
the harness stops waiting runs nothing."
  (harness-emacs-endpoint-test--with-eval
    (setq harness-emacs-endpoint-test--inner nil)
    (should (equal "(outer)"
                   (plist-get (harness-emacs-endpoint-test--eval
                               (concat "(setq harness-emacs-endpoint-test--inner"
                                       "      (harness-call 'emacs/request \"eval\""
                                       "                    '(:code \"(push 'inner harness-emacs-endpoint-test--order)\")))"
                                       "(sleep-for 0.3)"
                                       "(push 'outer harness-emacs-endpoint-test--order)"))
                              :value)))
    (should (harness-promise-p harness-emacs-endpoint-test--inner))
    (should (equal "(inner outer)" (plist-get (harness-test-await harness-emacs-endpoint-test--inner) :value)))
    (should (equal '(inner outer) harness-emacs-endpoint-test--order))
    (let ((harness-emacs-endpoint--evaluating t))
      (let ((r (harness-emacs-endpoint-test--eval "(push 'late harness-emacs-endpoint-test--order)"
                                                  :deadline (+ (float-time) 0.3) :host (system-name))))
        (should (eq 'failed (car r)))
        (should (string-search "another evaluation" (cadr r)))))
    (should (equal '(inner outer) harness-emacs-endpoint-test--order))))

(ert-deftest harness-emacs-endpoint-eval-says-when-code-leaves-by-a-non-local-exit ()
  "Code that throws past the evaluation fails the request, saying so,
and leaves this Emacs free for the next one."
  (harness-emacs-endpoint-test--setup)
  (let ((harness-emacs-eval t) (failed nil) (answered nil))
    (catch 'harness-emacs-endpoint-test--away
      (let ((inhibit-quit t))
        (harness-emacs-endpoint--eval '(:code "(throw 'harness-emacs-endpoint-test--away 1)")
                                      (lambda (r) (setq answered r))
                                      (lambda (m) (setq failed m)))))
    (should-not answered)
    (should (string-search "non-local exit" failed))
    (should-not harness-emacs-endpoint--evaluating)))

(ert-deftest harness-emacs-endpoint-a-deferred-request-is-answered-once ()
  "A request answered later gets one answer, whatever its method does."
  (harness-emacs-endpoint-test--setup)
  (let* ((responses nil)
         (harness-emacs-endpoint--deferred-methods
          (list (cons "twice" (lambda (_params answer fail)
                                (funcall answer '(:first t))
                                (funcall fail "second")
                                (funcall answer '(:third t)))))))
    (should (harness-emacs-endpoint-answer "_harness/emacs/twice" nil
                                           (lambda (r) (push r responses) t)))
    (should (equal '((:first t)) responses))))

;;;; Chores of the UI

(ert-deftest harness-emacs-endpoint-global-config-is-saved-by-the-ui ()
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (harness-test-load-module 'project)
    (harness-test-load-module 'config)
    (harness-test-connect-ui-client)
    ;; Like a normal session: customize refuses to save under "emacs -q".
    (let* ((init-file-user "")
           (user-init-file (expand-file-name "init.el" harness-state-directory))
           (custom-file (expand-file-name "custom.el" harness-state-directory))
           (harness-model harness-model))
      (harness-call 'config/set 'harness-model "demo:other" :scope 'global)
      (should (equal "demo:other" harness-model))
      (harness-test-wait (lambda () (file-exists-p custom-file)) 5 "custom file")
      (should (string-search "demo:other" (harness-read-file custom-file))))))

(ert-deftest harness-emacs-endpoint-customize-save-refuses-foreign-options ()
  (require 'harness-emacs-endpoint)
  (should-error (harness-emacs-endpoint-customize-save "fill-column" "70"))
  (should-error (harness-emacs-endpoint-customize-save nil "70")))

(provide 'harness-emacs-endpoint-test)
;;; harness-emacs-endpoint-test.el ends here
