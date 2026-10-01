;;; harness-perms-test.el --- Tests for the permission chain  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-perms-test--session nil
  "Plist returned by the fake `session/get'.")

(defvar harness-perms-test--pending nil
  "Pending requests added through the fake `session/pending-add'.")

(defvar harness-perms-test--resolved nil
  "(PID . ANSWER) pairs seen by the fake `session/pending-resolve'.")

(defun harness-perms-test--setup (&rest session)
  "Reset the bus, load the modules and install a fake session SESSION."
  (harness-test-reset-bus)
  (dolist (m '(project config tools provider perms))
    (harness-test-load-module m))
  (should (harness-module-ready-p 'perms))
  (clrhash harness-perms--allowed-dirs)
  (clrhash harness-perms--session-rules)
  (clrhash harness-perms--waiting)
  (setq harness-perms--steered nil
        harness-perms-rules nil
        harness-perms-test--pending nil
        harness-perms-test--resolved nil)
  (setq harness-perms-test--session
        (harness-plist-merge (list :id "s1" :cwd (harness-test-temp-dir) :permission-mode 'ask)
                             session))
  (harness-register-method 'session/get (lambda (_id) harness-perms-test--session))
  harness-perms-test--session)

(defun harness-perms-test--install-pending ()
  "Register fake `session/pending-add' and `session/pending-resolve'."
  (harness-register-method 'session/pending-add
                           (lambda (_sid req)
                             (let ((pid (format "p%d" (1+ (length harness-perms-test--pending)))))
                               (push (plist-put (copy-sequence req) :id pid) harness-perms-test--pending)
                               pid)))
  (harness-register-method 'session/pending-resolve
                           (lambda (_sid pid answer)
                             (push (cons pid answer) harness-perms-test--resolved)
                             (setq harness-perms-test--pending
                                   (cl-remove pid harness-perms-test--pending
                                              :key (lambda (p) (plist-get p :id)) :test #'equal)))))

(defun harness-perms-test--request (tool kind &rest paths)
  "Build a permission request for TOOL of KIND touching PATHS."
  (list :session harness-perms-test--session :tool tool :kind kind
        :input (list :path (car paths)) :paths paths :call-id (harness-short-id)))

(defun harness-perms-test--decide (request)
  "Run REQUEST through the whole chain and return the decision."
  (harness-test-await (harness-run-filter-async 'permission/decide (list :behavior 'ask) request)))

(defun harness-perms-test--behavior (tool kind &rest paths)
  "Return the decided behavior for a call to TOOL of KIND on PATHS."
  (plist-get (harness-perms-test--decide (apply #'harness-perms-test--request tool kind paths)) :behavior))

;;;; Jail

(ert-deftest harness-perms-jail-denies-outside-with-hint ()
  (let* ((s (harness-perms-test--setup :permission-mode 'yolo))
         (cwd (plist-get s :cwd))
         (outside (harness-test-temp-dir))
         (d (harness-perms-test--decide
             (harness-perms-test--request "read_file" 'read (expand-file-name "x.txt" outside)))))
    (should (eq 'deny (plist-get d :behavior)))
    (should (plist-get d :final))
    (should (string-match-p "outside the allowed directories" (plist-get d :reason)))
    ;; The hint lists the roots and names the directory to grant.
    (should (string-match-p (regexp-quote (abbreviate-file-name cwd)) (plist-get d :hint)))
    (should (string-match-p (regexp-quote (abbreviate-file-name outside)) (plist-get d :hint)))
    (should (string-match-p "allow-dir" (plist-get d :hint)))
    ;; Inside is fine, even in yolo the jail runs first.
    (should (eq 'allow (harness-perms-test--behavior "read_file" 'read (expand-file-name "a/b.txt" cwd))))
    ;; A sibling directory sharing a prefix is still outside.
    (should (eq 'deny (harness-perms-test--behavior
                       "read_file" 'read (concat (directory-file-name cwd) "-evil/x"))))))

(ert-deftest harness-perms-jail-worktree-config-and-runtime-roots ()
  (let* ((wt (harness-test-temp-dir))
         (extra (harness-test-temp-dir))
         (granted (harness-test-temp-dir))
         (outputs nil))
    (harness-test-with-temp-state
      (harness-perms-test--setup :permission-mode 'yolo :worktree wt)
      (setq outputs (expand-file-name "outputs/call.txt" harness-state-directory))
      (should (eq 'allow (harness-perms-test--behavior "read_file" 'read (expand-file-name "f" wt))))
      (should (eq 'deny (harness-perms-test--behavior "read_file" 'read (expand-file-name "f" extra))))
      (let ((harness-allowed-directories (list extra)))
        (should (eq 'allow (harness-perms-test--behavior "read_file" 'read (expand-file-name "f" extra)))))
      ;; Truncated tool outputs may always be range-read.
      (should (eq 'allow (harness-perms-test--behavior "read_file" 'read outputs)))
      ;; Runtime grants.
      (should (eq 'deny (harness-perms-test--behavior "write_file" 'write (expand-file-name "f" granted))))
      (let (events)
        (harness-on 'permission/dir-allowed (lambda (sid dir) (push (list sid dir) events)))
        (let ((roots (harness-call 'permission/allow-dir "s1" granted)))
          (should (member (file-name-as-directory granted) roots)))
        (should (equal (list "s1" (file-name-as-directory granted)) (car events))))
      (should (eq 'allow (harness-perms-test--behavior "write_file" 'write (expand-file-name "f" granted))))
      (should (member (file-name-as-directory granted) (harness-call 'permission/allowed-dirs "s1")))
      (should (member (file-name-as-directory wt) (harness-call 'permission/allowed-dirs "s1"))))))

(ert-deftest harness-perms-jail-passes-tools-without-paths ()
  (harness-perms-test--setup :permission-mode 'yolo)
  (should (eq 'allow (harness-perms-test--behavior "bash" 'exec)))
  (should (eq 'allow (harness-perms-test--behavior "web_fetch" 'net))))

(ert-deftest harness-perms-jail-compares-tramp-local-parts ()
  (harness-perms-test--setup :permission-mode 'yolo :cwd "/home/u/proj/" :host "/ssh:u@box:")
  (should (harness-perms--within-p "/ssh:u@box:/home/u/proj/" "/ssh:u@box:/home/u/proj/src/a.el"))
  (should-not (harness-perms--within-p "/ssh:u@box:/home/u/proj/" "/ssh:u@other:/home/u/proj/src/a.el"))
  (should-not (harness-perms--within-p "/ssh:u@box:/home/u/proj/" "/home/u/proj/src/a.el"))
  (should (eq 'allow (harness-perms-test--behavior "read_file" 'read "/ssh:u@box:/home/u/proj/a.el")))
  (should (eq 'deny (harness-perms-test--behavior "read_file" 'read "/ssh:u@box:/etc/passwd")))
  (should (eq 'deny (harness-perms-test--behavior "read_file" 'read "/home/u/proj/a.el"))))

(ert-deftest harness-perms-jail-through-tools-execute ()
  (let ((ran nil))
    (harness-perms-test--setup :permission-mode 'yolo)
    (harness-define-tool "t_read" :kind 'read :paths (lambda (in) (list (plist-get in :path)))
                         :handler (lambda (in _ctx) (setq ran t) (format "read %s" (plist-get in :path))))
    (let ((r (harness-test-await (harness-call 'tools/execute "s1" (list :id "c1" :name "t_read" :input (list :path "/etc/hostname"))))))
      (should (plist-get r :is-error))
      (should-not ran)
      (should (string-match-p "\\`Denied: /etc/hostname is outside the allowed directories Allowed roots:" (plist-get r :content))))
    (let ((r (harness-test-await (harness-call 'tools/execute "s1" (list :id "c2" :name "t_read" :input (list :path "inside.txt"))))))
      (should-not (plist-get r :is-error))
      (should ran)
      (should (equal "read inside.txt" (plist-get r :content))))))

;;;; Modes

(ert-deftest harness-perms-mode-matrix ()
  (let ((matrix '((ask allow deny deny)
                  (accept-edits allow allow deny)
                  (yolo allow allow allow))))
    (dolist (row matrix)
      (let* ((s (harness-perms-test--setup :permission-mode (car row)))
             (f (expand-file-name "f.txt" (plist-get s :cwd))))
        (should (eq (nth 1 row) (harness-perms-test--behavior "read_file" 'read f)))
        (should (eq (nth 2 row) (harness-perms-test--behavior "write_file" 'write f)))
        ;; Without a session module an open question is denied.
        (should (eq (nth 3 row) (harness-perms-test--behavior "bash" 'exec)))))))

(ert-deftest harness-perms-mode-falls-back-to-config ()
  (harness-perms-test--setup :permission-mode nil)
  (let ((harness-permission-mode 'yolo))
    (should (eq 'allow (harness-perms-test--behavior "bash" 'exec))))
  (let ((harness-permission-mode 'ask))
    (should (eq 'deny (harness-perms-test--behavior "bash" 'exec))))
  ;; A mode arriving as a string from the wire still works.
  (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode "accept-edits"))
  (should (eq 'allow (harness-perms-test--behavior "write_file" 'write
                                                   (expand-file-name "f" (plist-get harness-perms-test--session :cwd))))))

(ert-deftest harness-perms-auto-allow-tools ()
  (harness-perms-test--setup :permission-mode 'ask)
  (dolist (tool harness-perms-auto-allow-tools)
    (should (eq 'allow (harness-perms-test--behavior tool 'meta))))
  (should (eq 'deny (harness-perms-test--behavior "spawn_agent" 'meta)))
  (let ((harness-perms-auto-allow-tools '("spawn_agent")))
    (should (eq 'allow (harness-perms-test--behavior "spawn_agent" 'meta)))))

(ert-deftest harness-perms-standing-rules ()
  (harness-perms-test--setup :permission-mode 'ask)
  (should (eq 'deny (harness-perms-test--behavior "bash" 'exec)))
  (harness-perms-add-rule "s1" '(:tool "bash" :behavior allow) 'session)
  (should (eq 'allow (harness-perms-test--behavior "bash" 'exec)))
  (should (eq 'deny (harness-perms-test--behavior "elisp" 'exec)))
  ;; Another session does not inherit session rules.
  (setq harness-perms-test--session (plist-put harness-perms-test--session :id "s2"))
  (should (eq 'deny (harness-perms-test--behavior "bash" 'exec)))
  (harness-perms-add-rule "s2" '(:tool "bash" :behavior allow) 'always)
  (should (equal '((:tool "bash" :behavior allow)) harness-perms-rules))
  (should (eq 'allow (harness-perms-test--behavior "bash" 'exec)))
  ;; A deny rule beats the mode, with a hint.
  (let ((harness-perms-rules '((:tool "web_fetch" :behavior deny)))
        (harness-permission-mode 'yolo))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode 'yolo))
    (let ((d (harness-perms-test--decide (harness-perms-test--request "web_fetch" 'net))))
      (should (eq 'deny (plist-get d :behavior)))
      (should (plist-get d :hint))))
  ;; Kind-scoped rule.
  (let ((harness-perms-rules '((:kind exec :behavior allow))))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode 'ask))
    (should (eq 'allow (harness-perms-test--behavior "elisp" 'exec)))
    (should (eq 'deny (harness-perms-test--behavior "web_fetch" 'net))))
  (let ((rules (harness-call 'permission/rules "s2")))
    (should (eq 'ask (plist-get rules :mode)))
    (should (equal '((:tool "bash" :behavior allow)) (plist-get rules :always)))
    (should (plist-get rules :roots))))

;;;; Auto mode

(defun harness-perms-test--judge-provider (script)
  "Register provider `judge' that replays SCRIPT events asynchronously."
  (let ((cancelled nil) (requests nil))
    (harness-define-provider 'judge
      :label "Judge"
      :complete (lambda (req)
                  (push req requests)
                  (let ((cb (plist-get req :on-event)))
                    (dolist (ev script)
                      (let ((ev ev)) (run-at-time 0.01 nil (lambda () (funcall cb ev))))))
                  (list :cancel (lambda () (setq cancelled t)))))
    (lambda (what) (pcase what ('cancelled cancelled) ('requests requests)))))

(ert-deftest harness-perms-auto-mode-uses-the-judge ()
  (harness-perms-test--setup :permission-mode 'auto :model "judge:big")
  (harness-define-tool "t_exec" :kind 'exec :description "Runs a thing." :handler #'ignore)
  (let* ((probe (harness-perms-test--judge-provider
                 '((:type start)
                   (:type text :delta "Thinking... {\"decision\":")
                   (:type text :delta "\"deny\",\"reason\":\"scary\"}")
                   (:type done :stop-reason end-turn))))
         (harness-perms-auto-model "judge:small")
         (d (harness-perms-test--decide (list :session harness-perms-test--session :tool "t_exec"
                                              :kind 'exec :input '(:command "rm -rf /") :call-id "c9"))))
    (should (eq 'deny (plist-get d :behavior)))
    (should (equal "scary" (plist-get d :reason)))
    (let ((req (car (funcall probe 'requests))))
      (should (equal "judge:small" (plist-get req :model)))
      (should (null (plist-get req :tools)))
      (should (string-match-p "permission judge" (plist-get req :system)))
      (let ((text (plist-get (car (plist-get (car (plist-get req :messages)) :content)) :text)))
        (should (string-match-p "Runs a thing\\." text))
        (should (string-match-p "rm -rf /" text))
        (should (string-match-p (regexp-quote (plist-get harness-perms-test--session :cwd)) text)))))
  ;; A nil auto model falls back to the session's model; an allow verdict allows.
  (harness-perms-test--judge-provider
   '((:type text :delta "{\"decision\": \"allow\", \"reason\": \"harmless\"}")
     (:type done :stop-reason end-turn)))
  (let ((harness-perms-auto-model nil))
    (let ((d (harness-perms-test--decide (harness-perms-test--request "t_exec" 'exec))))
      (should (eq 'allow (plist-get d :behavior)))
      (should (equal "harmless" (plist-get d :reason))))))

(ert-deftest harness-perms-auto-mode-falls-back-to-ask ()
  (harness-perms-test--setup :permission-mode 'auto)
  ;; Garbage from the judge: back to ask, which nobody can answer here.
  (harness-perms-test--judge-provider '((:type text :delta "I refuse to answer in JSON") (:type done :stop-reason end-turn)))
  (let ((harness-perms-auto-model "judge:x"))
    (should (equal "no user available" (plist-get (harness-perms-test--decide (harness-perms-test--request "bash" 'exec)) :reason))))
  ;; Unknown provider: immediate done error, back to ask.
  (let ((harness-perms-auto-model "nope:x"))
    (should (equal "no user available" (plist-get (harness-perms-test--decide (harness-perms-test--request "bash" 'exec)) :reason))))
  ;; Timeout: the handle is cancelled and the chain proceeds.
  (let* ((probe (harness-perms-test--judge-provider '((:type start))))
         (harness-perms-auto-model "judge:x")
         (harness-perms-auto-timeout 0.2)
         (start (float-time))
         (d (harness-perms-test--decide (harness-perms-test--request "bash" 'exec))))
    (should (eq 'deny (plist-get d :behavior)))
    (should (equal "no user available" (plist-get d :reason)))
    (should (< (- (float-time) start) 5))
    (should (funcall probe 'cancelled)))
  ;; Reads are still allowed by the jail alone; the judge is not consulted.
  (let* ((probe (harness-perms-test--judge-provider '((:type start))))
         (harness-perms-auto-model "judge:x"))
    (should (eq 'allow (harness-perms-test--behavior "read_file" 'read
                                                     (expand-file-name "f" (plist-get harness-perms-test--session :cwd)))))
    (should (null (funcall probe 'requests)))))

;;;; Non-interactive

(ert-deftest harness-perms-non-interactive-denies-and-steers ()
  (harness-perms-test--setup :permission-mode 'ask :non-interactive t)
  (let (prompts)
    (harness-register-method 'agent/prompt (lambda (sid blocks) (push (cons sid blocks) prompts) (harness-resolved nil)))
    (let ((d (harness-perms-test--decide (harness-perms-test--request "bash" 'exec))))
      (should (eq 'deny (plist-get d :behavior)))
      (should (equal "non-interactive mode: the user is away" (plist-get d :reason)))
      (should (string-match-p "do not wait for the user" (plist-get d :hint))))
    (should (= 1 (length prompts)))
    (should (equal "s1" (caar prompts)))
    (should (equal "text" (plist-get (car (cdar prompts)) :type)))
    (should (string-match-p "bash" (plist-get (car (cdar prompts)) :text)))
    ;; The same call id does not steer twice; a new call does.
    (let ((req (harness-perms-test--request "bash" 'exec)))
      (harness-perms-test--decide req)
      (harness-perms-test--decide req)
      (should (= 2 (length prompts))))
    ;; Reads are unaffected, and so is a session that is interactive.
    (should (eq 'allow (harness-perms-test--behavior "read_file" 'read
                                                     (expand-file-name "f" (plist-get harness-perms-test--session :cwd)))))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :non-interactive nil))
    (should (equal "no user available" (plist-get (harness-perms-test--decide (harness-perms-test--request "bash" 'exec)) :reason)))
    (let ((harness-non-interactive t))
      (should (equal "non-interactive mode: the user is away"
                     (plist-get (harness-perms-test--decide (harness-perms-test--request "bash" 'exec)) :reason))))))

;;;; Asking the user

(ert-deftest harness-perms-ask-path-pending-and-answer ()
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (let* (requested
         (req (harness-perms-test--request "bash" 'exec))
         (_ (harness-on 'permission/requested (lambda (sid pending) (push (cons sid pending) requested))))
         (p (harness-run-filter-async 'permission/decide (list :behavior 'ask) req)))
    (harness-test-wait (lambda () requested) 2 "permission/requested")
    (should-not (harness-promise-settled-p p))
    (let* ((pending (cdar requested))
           (pid (plist-get pending :id)))
      (should (equal "s1" (caar requested)))
      (should (equal "p1" pid))
      (should (eq 'permission (plist-get pending :kind)))
      (should (equal "bash" (plist-get (plist-get pending :payload) :tool)))
      (should (equal harness-perms-options (plist-get (plist-get pending :payload) :options)))
      (should (stringp (plist-get (plist-get pending :payload) :title)))
      (should (equal (list pid) (mapcar (lambda (x) (plist-get x :id)) (harness-call 'permission/pending "s1"))))
      ;; Answer: allow for the session.
      (let ((d (harness-call 'permission/answer "s1" pid '(:behavior allow :scope session))))
        (should (eq 'allow (plist-get d :behavior))))
      (should (eq 'allow (plist-get (harness-test-await p) :behavior)))
      (should (equal pid (caar harness-perms-test--resolved)))
      (should (null (harness-call 'permission/pending "s1")))
      (should (null (hash-table-keys harness-perms--waiting))))
    ;; The session rule makes the next bash call pass without asking.
    (should (eq 'allow (harness-perms-test--behavior "bash" 'exec)))
    (should (= 1 (length harness-perms-test--resolved)))
    ;; Answering an unknown id is an error.
    (should-error (harness-call 'permission/answer "s1" "nope" '(:behavior allow)))))

(ert-deftest harness-perms-ask-path-deny-and-always ()
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (let ((p (harness-run-filter-async 'permission/decide (list :behavior 'ask) (harness-perms-test--request "elisp" 'exec))))
    (harness-test-wait (lambda () harness-perms-test--pending) 2 "pending")
    (let ((d (harness-call 'permission/answer "s1" (plist-get (car harness-perms-test--pending) :id)
                           '(:behavior deny :scope once :reason "not now"))))
      (should (eq 'deny (plist-get d :behavior)))
      (should (equal "not now" (plist-get d :reason))))
    (should (eq 'deny (plist-get (harness-test-await p) :behavior))))
  ;; Once means the next call asks again; an option id answer with scope always sticks.
  (let ((p (harness-run-filter-async 'permission/decide (list :behavior 'ask) (harness-perms-test--request "elisp" 'exec))))
    (harness-test-wait (lambda () harness-perms-test--pending) 2 "pending")
    (harness-call 'permission/answer "s1" (plist-get (car harness-perms-test--pending) :id) "deny-always")
    (should (eq 'deny (plist-get (harness-test-await p) :behavior)))
    (should (equal '((:tool "elisp" :behavior deny)) harness-perms-rules)))
  (should (eq 'deny (harness-perms-test--behavior "elisp" 'exec)))
  (should (null harness-perms-test--pending)))

;;;; Asking for a directory

(defun harness-perms-test--start (tool kind path)
  "Start deciding a call to TOOL of KIND on PATH; return (PROMISE . PENDING)."
  (let ((n (length harness-perms-test--pending))
        (p (harness-run-filter-async 'permission/decide (list :behavior 'ask)
                                     (harness-perms-test--request tool kind path))))
    (harness-test-wait (lambda () (> (length harness-perms-test--pending) n)) 2 "pending")
    (cons p (car harness-perms-test--pending))))

(ert-deftest harness-perms-jail-asks-and-grants-for-session ()
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (let* ((outside (harness-test-temp-dir))
         (file (expand-file-name "x.txt" outside))
         (started (harness-perms-test--start "read_file" 'read file))
         (p (car started))
         (payload (plist-get (cdr started) :payload)))
    (should-not (harness-promise-settled-p p))
    (should (equal outside (plist-get payload :dir)))
    (should (equal harness-perms-dir-options (plist-get payload :options)))
    (should (string-match-p "outside the allowed directories" (plist-get payload :reason)))
    (should (string-prefix-p "Access " (plist-get payload :title)))
    (should (eq 'continue (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "allow-session")))
    ;; The rest of the chain decides the call: a read inside the jail is allowed.
    (should (eq 'allow (plist-get (harness-test-await p) :behavior)))
    (should (member outside (harness-call 'permission/allowed-dirs "s1")))
    ;; The grant sticks: no new question for the next call.
    (should (eq 'allow (harness-perms-test--behavior "read_file" 'read (expand-file-name "y" outside))))
    (should (null harness-perms-test--pending))
    ;; A write still goes through the mode and asks about the tool itself.
    (let ((s (harness-perms-test--start "write_file" 'write file)))
      (should-not (plist-get (plist-get (cdr s) :payload) :dir))
      (harness-call 'permission/answer "s1" (plist-get (cdr s) :id) "deny-once")
      (should (eq 'deny (plist-get (harness-test-await (car s)) :behavior))))))

(ert-deftest harness-perms-jail-ask-once-deny-and-non-interactive ()
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (let* ((outside (harness-test-temp-dir))
         (file (expand-file-name "x.txt" outside)))
    ;; Allow once: this call passes, the next one asks again.
    (let ((s (harness-perms-test--start "read_file" 'read file)))
      (harness-call 'permission/answer "s1" (plist-get (cdr s) :id) "allow-once")
      (should (eq 'allow (plist-get (harness-test-await (car s)) :behavior))))
    (should-not (member outside (harness-call 'permission/allowed-dirs "s1")))
    (let ((s (harness-perms-test--start "read_file" 'read file)))
      (harness-call 'permission/answer "s1" (plist-get (cdr s) :id) "deny-once")
      (let ((d (harness-test-await (car s))))
        (should (eq 'deny (plist-get d :behavior)))
        (should (plist-get d :final))
        (should (string-match-p "denied access" (plist-get d :reason)))))
    ;; Nobody to ask: denied with the hint as before.
    (setq harness-perms-test--session (plist-put harness-perms-test--session :non-interactive t))
    (let ((d (harness-perms-test--decide (harness-perms-test--request "read_file" 'read file))))
      (should (eq 'deny (plist-get d :behavior)))
      (should (string-match-p "allow-dir" (plist-get d :hint))))
    (should (null harness-perms-test--pending))))

(ert-deftest harness-perms-dirs-always-and-revoke ()
  (let ((saved nil)
        (harness-allowed-directories nil)
        (a (harness-test-temp-dir))
        (b (harness-test-temp-dir)))
    (harness-test-with-temp-state
      (harness-perms-test--setup :permission-mode 'yolo)
      (cl-letf (((symbol-function 'harness-save-user-option)
                 (lambda (sym value) (set sym value) (push (cons sym value) saved))))
        ;; An always answer lands in the global option.
        (harness-perms-test--install-pending)
        (let ((s (harness-perms-test--start "read_file" 'read (expand-file-name "f" a))))
          (harness-call 'permission/answer "s1" (plist-get (cdr s) :id) "allow-always")
          (should (eq 'allow (plist-get (harness-test-await (car s)) :behavior))))
        (should (equal (list a) harness-allowed-directories))
        (should (eq 'harness-allowed-directories (caar saved)))
        (harness-call 'permission/allow-dir "s1" b)
        (let ((dirs (harness-call 'permission/dirs "s1")))
          (should (equal '(cwd config session outputs) (mapcar (lambda (e) (plist-get e :source)) dirs)))
          (should (equal '(nil t t nil) (mapcar (lambda (e) (plist-get e :revocable)) dirs))))
        ;; Revoking removes the session grant, then the global entry.
        (harness-call 'permission/revoke-dir "s1" b)
        (should-not (member b (harness-call 'permission/allowed-dirs "s1")))
        (harness-call 'permission/revoke-dir "s1" a)
        (should (null harness-allowed-directories))
        ;; The cwd is not a grant.
        (should-error (harness-call 'permission/revoke-dir "s1" (plist-get harness-perms-test--session :cwd)))))))

(ert-deftest harness-perms-describe-and-reload ()
  (harness-perms-test--setup)
  (harness-define-tool "t_titled" :kind 'exec :title (lambda (in) (format "run %s" (plist-get in :cmd))) :handler #'ignore)
  (should (equal "run ls" (harness-perms-describe-request '(:tool "t_titled" :input (:cmd "ls")))))
  (should (equal "bash echo hi" (harness-perms-describe-request '(:tool "bash" :input (:command "echo hi\nmore")))))
  ;; Re-running init keeps exactly one handler per stage.
  (harness-perms--init)
  (should (= 5 (length (gethash 'permission/decide harness--filters))))
  (should (memq 'permission/requested (mapcar #'car (harness-events)))))

(provide 'harness-perms-test)
;;; harness-perms-test.el ends here
