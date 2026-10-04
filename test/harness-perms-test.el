;;; harness-perms-test.el --- Tests for the permission chain  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-providers)

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
    (harness-define-tool "t_read" :label "Read" :kind 'read :paths (lambda (in) (list (plist-get in :path)))
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

(ert-deftest harness-perms--auto-allow-tools ()
  (harness-perms-test--setup :permission-mode 'ask)
  (dolist (tool harness-perms--auto-allow-tools)
    (should (eq 'allow (harness-perms-test--behavior tool 'meta))))
  (should (eq 'deny (harness-perms-test--behavior "spawn_agent" 'meta)))
  (let ((harness-perms--auto-allow-tools '("spawn_agent")))
    (should (eq 'allow (harness-perms-test--behavior "spawn_agent" 'meta)))))

(ert-deftest harness-perms-web-search-needs-no-approval ()
  ;; web_search only sends its query to the configured search provider,
  ;; so it is allowed in every mode; web_fetch reaches any host and asks.
  (harness-perms-test--setup :permission-mode 'ask)
  (should (member "web_search" harness-perms--auto-allow-tools))
  (should (eq 'allow (harness-perms-test--behavior "web_search" 'net)))
  (should (eq 'deny (harness-perms-test--behavior "web_fetch" 'net)))
  (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode 'accept-edits))
  (should (eq 'allow (harness-perms-test--behavior "web_search" 'net))))

(ert-deftest harness-perms-notify-needs-no-approval ()
  ;; notify only reaches the user, through the providers they set up, so
  ;; unattended sessions can tell them they are needed.
  (harness-perms-test--setup :permission-mode 'ask :non-interactive t)
  (should (member "notify" harness-perms--auto-allow-tools))
  (should (eq 'allow (harness-perms-test--behavior "notify" 'meta)))
  (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode 'auto))
  (should (eq 'allow (harness-perms-test--behavior "notify" 'meta))))

(ert-deftest harness-perms-hand-in-needs-no-approval ()
  "hand_in only records a task's report and ends the turn: no judge decides it.
The judge used to decide it.  It read in the tool's description that
the task then waits for review, and refused the edits the user's
feedback asked for afterwards; it also refused a hand-in over a
project's rule about landing work first."
  (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
  (should (member "hand_in" harness-perms--auto-allow-tools))
  (let* ((probe (harness-perms-test--judge-provider
                 '((:type text :delta "{\"decision\":\"deny\",\"reason\":\"land the work first\"}")
                   (:type done :stop-reason end-turn))))
         (harness-perms-auto-model "judge:x"))
    (should (eq 'allow (harness-perms-test--behavior "hand_in" 'meta)))
    (should (null (funcall probe 'requests)))))

(ert-deftest harness-perms-open-harness-needs-no-approval ()
  ;; open_harness only starts an Emacs running a checkout of the harness,
  ;; in a state directory of its own, so verifying harness work live needs
  ;; no prompt, in every mode.
  (harness-perms-test--setup :permission-mode 'ask)
  (should (member "open_harness" harness-perms--auto-allow-tools))
  (should (eq 'allow (harness-perms-test--behavior "open_harness" 'exec)))
  (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode 'auto))
  (should (eq 'allow (harness-perms-test--behavior "open_harness" 'exec))))

(ert-deftest harness-perms-rules-beat-auto-allow ()
  ;; web_search used to ask, so a user may have answered deny-always: the
  ;; rule must still hold now that the tool needs no approval.
  (harness-perms-test--setup :permission-mode 'ask)
  (let ((harness-perms-rules '((:tool "web_search" :behavior deny))))
    (let ((d (harness-perms-test--decide (harness-perms-test--request "web_search" 'net))))
      (should (eq 'deny (plist-get d :behavior)))
      (should (string-match-p "standing rule" (plist-get d :reason)))
      (should (plist-get d :hint)))
    ;; Only the named tool: the rest of the list still needs no approval.
    (should (eq 'allow (harness-perms-test--behavior "todo_write" 'meta))))
  ;; Session rules and kind rules apply as well.
  (harness-perms-add-rule "s1" '(:tool "todo_write" :behavior deny) 'session)
  (should (eq 'deny (harness-perms-test--behavior "todo_write" 'meta)))
  (harness-perms-add-rule "s1" '(:kind net :behavior deny) 'session)
  (should (eq 'deny (harness-perms-test--behavior "web_search" 'net))))

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

(defun harness-perms-test--scripted-judge (scripts)
  "Register provider `judge' replaying SCRIPTS, one per call, then a clean end.
Return a function giving the requests it received, newest first."
  (let ((requests nil) (left scripts))
    (harness-define-provider 'judge
      :label "Judge"
      :complete (lambda (req)
                  (push req requests)
                  (let ((cb (plist-get req :on-event))
                        (script (or (pop left) '((:type done :stop-reason end-turn)))))
                    (dolist (ev script)
                      (let ((ev ev)) (run-at-time 0.01 nil (lambda () (funcall cb ev))))))
                  (list :cancel #'ignore)))
    (lambda () requests)))

(ert-deftest harness-perms-auto-mode-uses-the-judge ()
  (harness-perms-test--setup :permission-mode 'auto :model "judge:big")
  (harness-define-tool "t_exec" :label "Run" :kind 'exec :description "Runs a thing." :handler #'ignore)
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

(ert-deftest harness-perms-judge-sees-the-call-alone ()
  "The judge rules on the safety of one call, with nothing else to go on.
Its request is one-off (`:ephemeral'), so the provider brings no
earlier verdicts and no project instructions.  Its prompt keeps it off
the task, the review and the workflow and has it lean to allowing.  Of
the tool's description it gets what the tool does, not how the agent
should use it.  A judge that remembered a hand-in, or read a project's
CLAUDE.md, refused a task's edits after the user sent it back."
  (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
  (harness-define-tool "t_exec" :label "Run" :kind 'exec
                       :description "Runs a thing in the shell. Prefer t_other over it, and hand the work in once done."
                       :handler #'ignore)
  (let* ((requests (harness-perms-test--scripted-judge
                    '(((:type text :delta "{\"decision\":\"deny\",\"reason\":\"it wipes the disk\"}")
                       (:type done :stop-reason end-turn))
                      ((:type text :delta "{\"decision\":\"allow\",\"reason\":\"ordinary work\"}")
                       (:type done :stop-reason end-turn)))))
         (harness-perms-auto-model "judge:x")
         (call (lambda (command)
                 (harness-perms-test--decide (list :session harness-perms-test--session :tool "t_exec" :kind 'exec
                                                   :input (list :command command) :call-id (harness-short-id)))))
         (denied (funcall call "dd if=/dev/zero of=/dev/sda"))
         (allowed (funcall call "make test"))
         (text-of (lambda (req) (plist-get (car (plist-get (car (plist-get req :messages)) :content)) :text))))
    (should (eq 'deny (plist-get denied :behavior)))
    (should (equal "it wipes the disk" (plist-get denied :reason)))
    (should (equal harness-perms-judge-deny-hint (plist-get denied :hint)))
    (should (eq 'allow (plist-get allowed :behavior)))
    ;; Newest first: each call was judged on its own command.
    (should (equal '("make test" "dd if=/dev/zero")
                   (mapcar (lambda (req) (if (string-search "make test" (funcall text-of req)) "make test"
                                           (and (string-search "dd if=/dev/zero" (funcall text-of req))
                                                "dd if=/dev/zero")))
                           (funcall requests))))
    (dolist (req (funcall requests))
      ;; One-off: the provider answers from this request alone.
      (should (eq t (plist-get req :ephemeral)))
      (should (= 1 (length (plist-get req :messages))))
      (should (null (plist-get req :provider-state)))
      ;; Safety only, leaning to allow; never the task or the workflow.
      (let ((system (plist-get req :system)))
        (should (string-search "never deny a call for such reasons" system))
        (should (string-search "handing work in" system))
        (should (string-search "temporary directories included" system))
        (should (string-search "When in doubt, allow" system)))
      ;; What the tool does, not how to use it.
      (let ((text (funcall text-of req)))
        (should (string-search "What it does: Runs a thing in the shell.\n" text))
        (should-not (string-search "Prefer t_other" text))
        (should-not (string-search "hand the work in" text)))))
  ;; The first sentence of a description, whatever it holds.
  (should (equal "(no description)" (harness-perms--what-it-does nil)))
  (should (equal "(no description)" (harness-perms--what-it-does "  ")))
  (should (equal "Runs a thing." (harness-perms--what-it-does "Runs a thing.")))
  (should (equal "Find files (e.g. \"*.el\")." (harness-perms--what-it-does "Find files (e.g. \"*.el\"). Results are capped.")))
  (should (equal "Run it." (harness-perms--what-it-does "Run it.  Then stop.\nMore.")))
  (should (equal "a lower-case start. no sentence break" (harness-perms--what-it-does "a lower-case start. no sentence break"))))

(ert-deftest harness-perms-auto-model-takes-the-providers-cheap-tier ()
  "`harness-perms-auto-model' `auto' judges with the session provider's cheap tier.
A model named by the provider's `:tiers' is used; an explicit model wins."
  (harness-perms-test--setup :permission-mode 'auto :model "judge2:big")
  (harness-define-tool "t_exec" :label "Run" :kind 'exec :description "Runs a thing." :handler #'ignore)
  (let ((requests nil))
    (harness-define-provider 'judge2
      :label "Judge 2"
      :models (lambda () (harness-resolved
                          (list (list :name "big" :pricing '(:input 10.0 :output 50.0))
                                (list :name "small" :pricing '(:input 1.0 :output 5.0))
                                (list :name "mid" :pricing '(:input 3.0 :output 15.0)))))
      ;; Not the cheapest: the declared tier is what decides.
      :tiers '(:cheap "mid")
      :complete (lambda (req)
                  (push req requests)
                  (let ((cb (plist-get req :on-event)))
                    (run-at-time 0.01 nil (lambda ()
                                            (funcall cb (list :type 'text :delta "{\"decision\":\"allow\",\"reason\":\"fine\"}"))
                                            (funcall cb '(:type done :stop-reason end-turn)))))
                  (list :cancel #'ignore)))
    (unwind-protect
        (progn
          ;; The symbol and the string `auto' (as config JSON gives it).
          (dolist (choice (list 'auto "auto"))
            (setq requests nil)
            (let ((harness-perms-auto-model choice))
              (should (eq 'allow (plist-get (harness-perms-test--decide
                                             (harness-perms-test--request "t_exec" 'exec))
                                            :behavior)))
              (should (equal "judge2:mid" (plist-get (car requests) :model)))))
          ;; An explicit model wins.
          (setq requests nil)
          (let ((harness-perms-auto-model "judge2:big"))
            (harness-perms-test--decide (harness-perms-test--request "t_exec" 'exec))
            (should (equal "judge2:big" (plist-get (car requests) :model)))))
      (remhash 'judge2 harness-providers))))

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
         (harness-perms--auto-timeout 0.2)
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

(ert-deftest harness-perms-auto-mode-asks-again-when-the-judge-ran-out-of-tokens ()
  "A judge that spends its whole output budget thinking is asked again.
A reasoning model writes no verdict before `max-tokens'; the second call
gets `harness-perms--judge-retry-max-tokens', and its verdict decides the
call, so a non-interactive session is not refused one nobody judged."
  (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
  (let* ((requests (harness-perms-test--scripted-judge
                    '(((:type text :delta "{\"decision\":")
                       (:type done :stop-reason max-tokens))
                      ((:type text :delta "{\"decision\":\"allow\",\"reason\":\"ordinary work\"}")
                       (:type done :stop-reason end-turn)))))
         (harness-perms-auto-model "judge:x")
         (d (harness-perms-test--decide (harness-perms-test--request "bash" 'exec))))
    (should (eq 'allow (plist-get d :behavior)))
    (should (equal "ordinary work" (plist-get d :reason)))
    (should (= 2 (length (funcall requests))))
    ;; Newest first: the first call kept the small budget, the retry the large one.
    (should (equal harness-perms--judge-max-tokens
                   (plist-get (cadr (funcall requests)) :max-tokens)))
    (should (equal harness-perms--judge-retry-max-tokens
                   (plist-get (car (funcall requests)) :max-tokens)))))

(ert-deftest harness-perms-auto-mode-takes-a-verdict-written-before-the-cap ()
  "A complete JSON verdict stands even when the model talks on to `max-tokens'."
  (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
  (let* ((requests (harness-perms-test--scripted-judge
                    '(((:type text :delta "{\"decision\":\"allow\",\"reason\":\"fine\"} and more")
                       (:type done :stop-reason max-tokens)))))
         (harness-perms-auto-model "judge:x")
         (d (harness-perms-test--decide (harness-perms-test--request "bash" 'exec))))
    (should (eq 'allow (plist-get d :behavior)))
    (should (equal "fine" (plist-get d :reason)))
    (should (= 1 (length (funcall requests))))))

(ert-deftest harness-perms-auto-mode-a-verdict-ending-at-max-tokens-decides ()
  "A parseable verdict decides even when the completion stopped at max-tokens.
The judge used to require `end-turn' and so discarded verdicts like
these, from the log, then denied ordinary unattended work.  The judge
asks for no extended thinking, which spent its output before the verdict."
  (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
  (harness-define-tool "t_edit" :label "Edit" :kind 'write :description "Edits a file." :handler #'ignore)
  (pcase-dolist (`(,reply ,behavior ,reason)
                 '(("{\"decision\":\"allow\",\"reason\":\"Ordinary source edit within the project worktree.\"}"
                    allow "Ordinary source edit within the project worktree.")
                   ("{\"decision\":\"deny\",\"reason\":\"Outside the project.\"}"
                    deny "Outside the project.")))
    (let* ((requests (harness-perms-test--scripted-judge
                      `(((:type text :delta ,reply) (:type done :stop-reason max-tokens)))))
           (harness-perms-auto-model "judge:x")
           (d (harness-perms-test--decide (harness-perms-test--request "t_edit" 'write))))
      (should (eq behavior (plist-get d :behavior)))
      (should (equal reason (plist-get d :reason)))
      (should-not (plist-get d :no-verdict))
      ;; Decided at once, without the retry; and with thinking off.
      (should (= 1 (length (funcall requests))))
      (should (eq t (plist-get (car (funcall requests)) :no-thinking))))))

(ert-deftest harness-perms-auto-mode-a-cut-verdict-at-max-tokens-is-no-verdict ()
  "A reply cut off before its verdict is complete gives no verdict, whatever it began.
Nothing is read into half a JSON object, so a non-interactive session
denies the call as nobody's verdict, after the one retry."
  (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
  (let* ((cut '((:type text :delta "{\"decision\":\"allow\",\"reason\":\"")
                (:type done :stop-reason max-tokens)))
         (requests (harness-perms-test--scripted-judge (list cut cut)))
         (harness-perms-auto-model "judge:x")
         (d (harness-perms-test--decide (harness-perms-test--request "bash" 'exec))))
    (should (eq 'deny (plist-get d :behavior)))
    (should (equal harness-perms-no-verdict-hint (plist-get d :hint)))
    (should (string-match-p "no verdict (it stopped: max-tokens)" (plist-get d :reason)))
    (should (= 2 (length (funcall requests)))))
  (should-not (harness-perms--parse-verdict "{\"decision\":\"allow\",\"reason\":\""))
  (should-not (harness-perms--parse-verdict "{\"decision\":\"maybe\",\"reason\":\"unsure\"}"))
  (should-not (harness-perms--parse-verdict "")))

(defconst harness-perms-test--non-ascii "\N{U+2717} caf\N{U+E9} 3 \N{U+D7} 4 \N{U+2026}"
  "Text with a ballot X, an accented letter, a multiplication sign and an ellipsis.")

(defun harness-perms-test--encoding-judge (reply)
  "Register provider `judge' that encodes each request as JSON, then answers REPLY.
Real providers encode the request before they send it.  Return a
function giving the judge prompts they encoded, newest first."
  (let ((sent nil))
    (harness-define-provider 'judge
      :label "Judge"
      :complete (lambda (req)
                  (let ((json (harness-json-encode (list :system (plist-get req :system)
                                                         :messages (plist-get req :messages))))
                        (cb (plist-get req :on-event)))
                    (push (harness-plist-get-in
                           (car (plist-get (car (plist-get (harness-json-parse json) :messages)) :content))
                           '(:text))
                          sent)
                    (run-at-time 0.01 nil (lambda ()
                                            (funcall cb (list :type 'text :delta reply))
                                            (funcall cb '(:type done :stop-reason end-turn)))))
                  (list :cancel #'ignore)))
    (lambda () sent)))

(ert-deftest harness-perms-judge-text-of-non-ascii-input-encodes-again ()
  ;; A provider sends the judge text as JSON.  The input used to go in as
  ;; bytes, which became raw-byte characters, and then that encoding
  ;; failed with (wrong-type-argument json-value-p ...).
  (harness-perms-test--setup :permission-mode 'auto)
  (let* ((input (list :path "notes.md" :old_string "- [ ] todo"
                      :new_string (concat "- " harness-perms-test--non-ascii)))
         (text (harness-perms--judge-text (list :session harness-perms-test--session :tool "edit_file"
                                                :kind 'write :input input))))
    (should (string-search (harness-json-encode-text input) text))
    (should (string-search harness-perms-test--non-ascii text))
    (should (equal text (plist-get (harness-json-parse (harness-json-encode (list :text text))) :text)))))

(ert-deftest harness-perms-auto-mode-judges-non-ascii-input ()
  ;; The judge's verdict on a non-ASCII input stands: an interactive session
  ;; is not asked needlessly, a non-interactive one (every task) not refused
  ;; because the user is away.
  (harness-perms-test--setup :permission-mode 'auto)
  (harness-define-tool "t_edit" :label "Edit" :kind 'write :description "Edits a file." :handler #'ignore)
  (let* ((sent (harness-perms-test--encoding-judge "{\"decision\":\"allow\",\"reason\":\"an ordinary edit\"}"))
         (harness-perms-auto-model "judge:small")
         (request (lambda () (list :session harness-perms-test--session :tool "t_edit" :kind 'write
                                   :input (list :path "notes.md" :new_string harness-perms-test--non-ascii)
                                   :call-id (harness-short-id))))
         (d (harness-perms-test--decide (funcall request))))
    (should (eq 'allow (plist-get d :behavior)))
    (should (equal "an ordinary edit" (plist-get d :reason)))
    ;; The judge saw the input as it is.
    (should (string-search harness-perms-test--non-ascii (car (funcall sent))))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :non-interactive t))
    (should (eq 'allow (plist-get (harness-perms-test--decide (funcall request)) :behavior)))
    (harness-perms-test--encoding-judge "{\"decision\":\"deny\",\"reason\":\"not that file\"}")
    (let ((d (harness-perms-test--decide (funcall request))))
      (should (eq 'deny (plist-get d :behavior)))
      (should (equal "not that file" (plist-get d :reason))))))

(ert-deftest harness-perms-auto-mode-logs-why-there-is-no-verdict ()
  (harness-perms-test--setup :permission-mode 'auto)
  (let* ((logged nil)
         (harness-log-hook (list (lambda (level msg) (when (eq level 'warn) (push msg logged)))))
         (warning (lambda ()
                    (setq logged nil)
                    (harness-perms-test--decide (harness-perms-test--request "bash" 'exec))
                    (cl-find-if (lambda (m) (string-prefix-p "perms: auto judge" m)) logged))))
    ;; A provider failing before it sends: its error is in the warning.
    (harness-define-provider 'judge :label "Judge"
                             :complete (lambda (_req) (error "Cannot encode the request")))
    (let ((harness-perms-auto-model "judge:x"))
      (should (equal "perms: auto judge gave no verdict for bash (error): Cannot encode the request"
                     (funcall warning))))
    (let ((harness-perms-auto-model "nope:x"))
      (should (equal "perms: auto judge gave no verdict for bash (error): No provider for model nope:x"
                     (funcall warning))))
    ;; A reply without a verdict is quoted.
    (harness-perms-test--judge-provider '((:type text :delta "I refuse to answer in JSON")
                                          (:type done :stop-reason end-turn)))
    (let ((harness-perms-auto-model "judge:x"))
      (should (equal "perms: auto judge gave no verdict for bash (end-turn); it replied: I refuse to answer in JSON"
                     (funcall warning))))))

;;;; Non-interactive

(defun harness-perms-test--allowing-judge ()
  "Register provider `judge' that allows every call; return its probe."
  (harness-perms-test--judge-provider '((:type text :delta "{\"decision\":\"allow\",\"reason\":\"ordinary work\"}")
                                        (:type done :stop-reason end-turn))))

(ert-deftest harness-perms-non-interactive-the-judge-decides-for-the-user ()
  "Non-interactive mode refuses nothing by itself: what would ask the
user, who is away, the judge decides in every mode, and its verdict
stands, an allow as much as a deny.  spawn_agent used to be refused
whenever the judge was not the one deciding."
  (harness-perms-test--setup :permission-mode 'ask :non-interactive t)
  (let ((harness-perms-auto-model "judge:small")
        (harness-perms--auto-timeout 2))
    (dolist (mode '(ask accept-edits auto))
      (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode mode))
      (let* ((probe (harness-perms-test--allowing-judge))
             (d (harness-perms-test--decide (list :session harness-perms-test--session :tool "spawn_agent" :kind 'meta
                                                  :input '(:prompt "Fix the parser \N{U+2014} quickly")
                                                  :call-id (harness-short-id)))))
        (should (eq 'allow (plist-get d :behavior)))
        (should (equal "ordinary work" (plist-get d :reason)))
        (should (= 1 (length (funcall probe 'requests))))))
    ;; The judge's denial stands as it gave it.
    (harness-perms-test--judge-provider '((:type text :delta "{\"decision\":\"deny\",\"reason\":\"too risky\"}")
                                          (:type done :stop-reason end-turn)))
    (let ((d (harness-perms-test--decide (harness-perms-test--request "bash" 'exec))))
      (should (eq 'deny (plist-get d :behavior)))
      (should (equal "too risky" (plist-get d :reason))))
    ;; What the mode or a rule decides needs no judge.
    (let ((probe (harness-perms-test--allowing-judge)))
      (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode 'ask))
      (should (eq 'allow (harness-perms-test--behavior "read_file" 'read
                                                       (expand-file-name "f" (plist-get harness-perms-test--session :cwd)))))
      (harness-perms-add-rule "s1" '(:tool "elisp" :behavior deny) 'session)
      (should (eq 'deny (harness-perms-test--behavior "elisp" 'exec)))
      (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode 'yolo))
      (should (eq 'allow (harness-perms-test--behavior "bash" 'exec)))
      (should (null (funcall probe 'requests)))
      ;; Interactive, ask mode asks the user, not the judge (nobody can
      ;; answer here).
      (setq harness-perms-test--session (plist-put (plist-put harness-perms-test--session :permission-mode 'ask)
                                                   :non-interactive nil))
      (should (equal "no user available" (plist-get (harness-perms-test--decide (harness-perms-test--request "bash" 'exec))
                                                    :reason)))
      (should (null (funcall probe 'requests)))
      (should-not (plist-get (harness-call 'permission/rules "s1") :non-interactive)))))

(ert-deftest harness-perms-non-interactive-denies-only-without-a-verdict ()
  "A call the judge gave no verdict on cannot be approved while the user
is away, so it is denied; the reason says why there was no verdict."
  (harness-perms-test--setup :permission-mode 'ask :non-interactive t)
  (let ((reason (lambda ()
                  (let ((d (harness-perms-test--decide (harness-perms-test--request "spawn_agent" 'meta))))
                    (should (eq 'deny (plist-get d :behavior)))
                    (should (equal harness-perms-no-verdict-hint (plist-get d :hint)))
                    (plist-get d :reason)))))
    (harness-perms-test--judge-provider '((:type text :delta "I refuse to answer in JSON")
                                          (:type done :stop-reason end-turn)))
    (let ((harness-perms-auto-model "judge:x"))
      (should (equal (concat "the auto-mode judge gave no verdict (its answer held no verdict), "
                             "and with the user away nobody could approve the call")
                     (funcall reason))))
    (let ((harness-perms-auto-model "nope:x"))
      (should (string-match-p "no verdict (it failed: No provider for model nope:x)" (funcall reason))))
    (harness-define-provider 'judge :label "Judge" :complete (lambda (_req) (error "Cannot encode the request")))
    (let ((harness-perms-auto-model "judge:x"))
      (should (string-match-p "no verdict (it failed: Cannot encode the request)" (funcall reason))))
    (let* ((probe (harness-perms-test--judge-provider
                   '((:type text :delta "{\"decision\":") (:type done :stop-reason max-tokens))))
           (harness-perms-auto-model "judge:x"))
      (should (string-match-p "no verdict (it stopped: max-tokens)" (funcall reason)))
      ;; Truncation once is retried at the larger budget; twice is a denial.
      (should (= 2 (length (funcall probe 'requests)))))
    (let ((probe (harness-perms-test--judge-provider '((:type start))))
          (harness-perms-auto-model "judge:x")
          (harness-perms--auto-timeout 0.2))
      (should (string-match-p "no verdict (it took longer than 0.2s)" (funcall reason)))
      (should (funcall probe 'cancelled))))
  ;; No judge to ask at all.
  (harness-unregister-method 'provider/complete)
  (let ((d (harness-perms-test--decide (harness-perms-test--request "bash" 'exec))))
    (should (eq 'deny (plist-get d :behavior)))
    (should (string-match-p "no auto-mode judge could decide" (plist-get d :reason)))
    (should (equal harness-perms-non-interactive-hint (plist-get d :hint)))))

(defun harness-perms-test--prompts ()
  "Register a fake `agent/prompt' that records what it is sent.
Return a function giving the (SESSION-ID . TEXT) pairs, newest first."
  (let ((prompts nil))
    (harness-register-method 'agent/prompt
                             (lambda (sid blocks &rest _)
                               (push (cons sid (plist-get (car blocks) :text)) prompts)
                               (harness-resolved nil)))
    (lambda () prompts)))

(ert-deftest harness-perms-non-interactive-steers-after-every-denial ()
  "With the user away, any denial is followed by a steering message,
once per call, whoever made it: the judge, the jail or a rule."
  (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
  (harness-define-tool "t_exec" :label "Run" :kind 'exec :handler (lambda (_in _ctx) "ran"))
  (harness-define-tool "t_read" :label "Read" :kind 'read :paths (lambda (in) (list (plist-get in :path)))
                       :handler (lambda (_in _ctx) "read"))
  (let* ((prompts (harness-perms-test--prompts))
         (harness-perms-auto-model "judge:small")
         (run (lambda (id name input)
                (harness-test-await (harness-call 'tools/execute "s1" (list :id id :name name :input input)))))
         (count (lambda () (length (funcall prompts)))))
    (harness-perms-test--judge-provider '((:type text :delta "{\"decision\":\"deny\",\"reason\":\"not that\"}")
                                          (:type done :stop-reason end-turn)))
    (let ((r (funcall run "c1" "t_exec" '(:command "x"))))
      (should (plist-get r :denied))
      (should (string-match-p "\\`Denied: not that" (plist-get r :content))))
    (should (equal (list (cons "s1" (format harness-perms-steering-text "t_exec"))) (funcall prompts)))
    (should (string-match-p "user is away, so do not wait for them" (cdar (funcall prompts))))
    ;; The jail's denial, and a standing rule's.
    (should (plist-get (funcall run "c2" "t_read" '(:path "/etc/hostname")) :denied))
    (should (= 2 (funcall count)))
    (should (string-match-p "\\`The call to t_read was denied" (cdar (funcall prompts))))
    (harness-perms-add-rule "s1" '(:tool "t_exec" :behavior deny) 'session)
    (funcall run "c3" "t_exec" '(:command "y"))
    (should (= 3 (funcall count)))
    ;; Once per call.
    (funcall run "c3" "t_exec" '(:command "y"))
    (should (= 3 (funcall count)))
    ;; Allowed calls steer nothing.
    (should (equal "read" (plist-get (funcall run "c4" "t_read" '(:path "inside.txt")) :content)))
    (should (= 3 (funcall count)))
    ;; Without a turn to take it, nothing is sent: that would start one.
    (harness-register-method 'agent/running (lambda (&optional _sid) nil))
    (funcall run "c5" "t_exec" '(:command "z"))
    (should (= 3 (funcall count)))
    (harness-register-method 'agent/running (lambda (&optional _sid) t))
    (funcall run "c6" "t_exec" '(:command "z"))
    (should (= 4 (funcall count)))
    ;; Interactive, the denial is only the call's result: the user is there.
    (setq harness-perms-test--session (plist-put harness-perms-test--session :non-interactive nil))
    (should (plist-get (funcall run "c7" "t_exec" '(:command "z")) :denied))
    (should (= 4 (funcall count)))))

(ert-deftest harness-perms-non-interactive-steering-comes-from-the-harness ()
  "The steering after a denial is marked as the harness's, not the user's:
the chat shows it as a system message, never as the user's own words."
  (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
  (harness-define-tool "t_exec" :label "Run" :kind 'exec :handler (lambda (_in _ctx) "ran"))
  (let ((sent nil)
        (harness-perms-auto-model "judge:small"))
    (harness-register-method 'agent/prompt
                             (lambda (sid blocks &optional opts)
                               (push (list sid blocks opts) sent)
                               (harness-resolved nil)))
    (harness-perms-test--judge-provider '((:type text :delta "{\"decision\":\"deny\",\"reason\":\"not that\"}")
                                          (:type done :stop-reason end-turn)))
    (should (plist-get (harness-test-await (harness-call 'tools/execute "s1" (list :id "c1" :name "t_exec"
                                                                                   :input '(:command "x"))))
                       :denied))
    (should (= 1 (length sent)))
    (should (equal (harness-sender-system "non-interactive mode")
                   (plist-get (nth 2 (car sent)) :from)))))

(ert-deftest harness-perms-non-interactive-is-the-sessions-own-switch ()
  "A session record's switch decides, off as much as on; the setting
`harness-non-interactive' only starts new sessions, and decides alone
for a request without a session record."
  (let* ((s (harness-perms-test--setup :permission-mode 'ask :non-interactive nil))
         (cwd (plist-get s :cwd))
         (harness-perms-auto-model "nope:x")
         (away "\\`the auto-mode judge gave no verdict .*with the user away nobody could approve")
         (reason (lambda () (plist-get (harness-perms-test--decide (harness-perms-test--request "bash" 'exec)) :reason))))
    (harness-register-method 'agent/prompt (lambda (&rest _) (harness-resolved nil)))
    (let ((harness-non-interactive t))
      ;; Turned off in the session, as the UI sends it (false) or as stored (nil).
      (dolist (off '(nil :false))
        (setq harness-perms-test--session (plist-put harness-perms-test--session :non-interactive off))
        (should (equal "no user available" (funcall reason)))
        (should-not (plist-get (harness-call 'permission/rules "s1") :non-interactive)))
      ;; Without a session record, the setting decides.
      (setq harness-perms-test--session (list :id "s1" :cwd cwd :permission-mode 'ask))
      (should (string-match-p away (funcall reason)))
      (should (plist-get (harness-call 'permission/rules "s1") :non-interactive)))
    ;; And the session's switch on wins over the setting off.
    (let ((harness-non-interactive nil))
      (setq harness-perms-test--session (plist-put harness-perms-test--session :non-interactive t))
      (should (string-match-p away (funcall reason)))
      (should (plist-get (harness-call 'permission/rules "s1") :non-interactive)))))

(ert-deftest harness-perms-task-sessions-can-search-the-web ()
  ;; Task sessions run in auto mode, non-interactive.  web_search used to
  ;; be left to the judge, which often denied network access as out of
  ;; scope; whatever it left undecided was denied as nobody could answer.
  (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
  (harness-test-load-module 'tools-web)
  (let* ((probe (harness-perms-test--judge-provider
                 '((:type text :delta "{\"decision\":\"deny\",\"reason\":\"network calls are out of scope\"}")
                   (:type done :stop-reason end-turn))))
         (harness-perms-auto-model "judge:small")
         (harness-websearch-providers nil)
         (harness-websearch-provider 'fake)
         (prompts nil))
    (harness-register-method 'agent/prompt (lambda (sid blocks &rest _) (push (cons sid blocks) prompts) (harness-resolved nil)))
    (harness-websearch-register-provider
     'fake (lambda (query _count) (list (list :title (concat "About " query) :url "https://example.org/"))))
    (let ((r (harness-test-await (harness-call 'tools/execute "s1"
                                               (list :id "c1" :name "web_search" :input '(:query "emacs"))))))
      (should-not (plist-get r :is-error))
      (should (string-match-p "About emacs" (plist-get r :content))))
    ;; Decided without asking the judge, and nothing to steer.
    (should (null (funcall probe 'requests)))
    (should (null prompts))
    ;; web_fetch can reach any host, so the judge still decides it.
    (let ((d (harness-perms-test--decide (list :session harness-perms-test--session :tool "web_fetch" :kind 'net
                                               :input '(:url "https://example.org/") :call-id "c2"))))
      (should (eq 'deny (plist-get d :behavior)))
      (should (equal "network calls are out of scope" (plist-get d :reason))))
    (should (= 1 (length (funcall probe 'requests))))))

(ert-deftest harness-perms-provider-search-is-web-search ()
  ;; A model provider's own search stands in for web_search, so the
  ;; rules for web_search decide it: no approval, even unattended, unless
  ;; a standing rule says otherwise.
  (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
  (harness-test-load-module 'tools-web)
  (let ((probe (harness-perms-test--judge-provider
                '((:type text :delta "{\"decision\":\"deny\",\"reason\":\"no\"}")
                  (:type done :stop-reason end-turn))))
        (harness-perms-auto-model "judge:small"))
    (harness-register-method 'agent/prompt (lambda (&rest _) (harness-resolved nil)))
    (let ((d (harness-test-await (harness-call 'tools/authorize "s1"
                                               '(:id "c1" :name "web_search" :input (:query "emacs"))))))
      (should (eq 'allow (plist-get d :behavior)))
      (should (string-match-p "never needs approval" (plist-get d :reason))))
    (should (null (funcall probe 'requests)))
    (let* ((harness-perms-rules '((:tool "web_search" :behavior deny)))
           (d (harness-test-await (harness-call 'tools/authorize "s1"
                                                '(:id "c2" :name "web_search" :input (:query "emacs"))))))
      (should (eq 'deny (plist-get d :behavior)))
      (should (string-match-p "\\`Denied: denied by a standing rule for web_search" (plist-get d :message))))))

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

;;;; Directory requests from the agent

(defvar harness-sessions)

(defun harness-perms-test--real (dir)
  "Return DIR with symbolic links resolved, as a directory name."
  (file-name-as-directory (file-truename dir)))

(defun harness-perms-test--dir-request (path &optional reason)
  "Build a permission request for the request tool asking for PATH with REASON."
  (list :session harness-perms-test--session :tool harness-perms-dir-tool :kind 'meta
        :input (append (list :path path) (and reason (list :reason reason)))
        :call-id (harness-short-id)))

(defun harness-perms-test--start-request (path &optional reason)
  "Start deciding a request for PATH with REASON; return (PROMISE . PENDING)."
  (let ((n (length harness-perms-test--pending))
        (p (harness-run-filter-async 'permission/decide (list :behavior 'ask)
                                     (harness-perms-test--dir-request path reason))))
    (harness-test-wait (lambda () (> (length harness-perms-test--pending) n)) 2 "pending")
    (cons p (car harness-perms-test--pending))))

(ert-deftest harness-perms-dir-request-tool-is-registered ()
  (harness-perms-test--setup)
  (let ((spec (harness-call 'tools/get "request_directory_access")))
    (should spec)
    (should (eq 'meta (plist-get spec :kind)))
    (should (equal '("path" "reason") (plist-get (plist-get spec :schema) :required)))
    (should (string-match-p "always asked" (plist-get spec :description)))))

(ert-deftest harness-perms-dir-request-asks-and-grants-for-session ()
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (let* ((outside (harness-test-temp-dir))
         (started (harness-perms-test--start-request outside "Read the shared API types"))
         (p (car started))
         (pending (cdr started))
         (payload (plist-get pending :payload)))
    (should-not (harness-promise-settled-p p))
    (should (eq 'permission (plist-get pending :kind)))
    (should (equal "request_directory_access" (plist-get payload :tool)))
    (should (equal (harness-perms-test--real outside) (plist-get payload :dir)))
    (should (string-prefix-p "Access " (plist-get payload :title)))
    ;; No "allow once": there is no single call to allow.
    (should (equal harness-perms-dir-request-options (plist-get payload :options)))
    (should (string-match-p "The agent asks for access: Read the shared API types" (plist-get payload :reason)))
    ;; The reason is shown once: the input keeps only the path.
    (should (equal (list :path outside) (plist-get payload :input)))
    (should-not (member (harness-perms-test--real outside) (harness-call 'permission/allowed-dirs "s1")))
    (let ((d (harness-call 'permission/answer "s1" (plist-get pending :id) "allow-session")))
      (should (eq 'allow (plist-get d :behavior)))
      (should (plist-get d :final)))
    (let ((d (harness-test-await p)))
      (should (eq 'allow (plist-get d :behavior)))
      (should (string-match-p "to this session" (plist-get d :reason))))
    (should (equal (plist-get pending :id) (caar harness-perms-test--resolved)))
    (should (member (harness-perms-test--real outside) (harness-call 'permission/allowed-dirs "s1")))
    (should (null (hash-table-keys harness-perms--waiting)))
    ;; The jail lets files there through now, and asking again needs no answer.
    (should (eq 'allow (harness-perms-test--behavior "read_file" 'read (expand-file-name "x" outside))))
    (let ((d (harness-perms-test--decide (harness-perms-test--dir-request outside))))
      (should (eq 'allow (plist-get d :behavior)))
      (should (string-match-p "already allowed" (plist-get d :reason))))
    (should (null harness-perms-test--pending))))

(ert-deftest harness-perms-dir-request-only-the-user-decides ()
  "No mode, standing rule, auto-allow entry or auto-mode judge grants a directory."
  (dolist (mode '(ask accept-edits auto yolo))
    (harness-perms-test--setup :permission-mode mode)
    (harness-perms-test--install-pending)
    (let* ((probe (harness-perms-test--judge-provider
                   '((:type text :delta "{\"decision\":\"allow\",\"reason\":\"fine\"}")
                     (:type done :stop-reason end-turn))))
           (harness-perms-auto-model "judge:x")
           (harness-perms-rules '((:behavior allow)))
           (harness-perms--auto-allow-tools (cons harness-perms-dir-tool harness-perms--auto-allow-tools))
           (outside (harness-test-temp-dir))
           (started (harness-perms-test--start-request outside "need it")))
      ;; The call waits for the user, whatever the mode says.
      (accept-process-output nil 0.1)
      (should-not (harness-promise-settled-p (car started)))
      (should-not (member (harness-perms-test--real outside) (harness-call 'permission/allowed-dirs "s1")))
      (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "deny-once")
      (let ((d (harness-test-await (car started))))
        (should (eq 'deny (plist-get d :behavior)))
        (should (plist-get d :final))
        (should (string-match-p "denied access" (plist-get d :reason)))
        (should (string-match-p "Do not ask for it again" (plist-get d :hint))))
      (should-not (member (harness-perms-test--real outside) (harness-call 'permission/allowed-dirs "s1")))
      ;; The judge never saw the request.
      (should (null (funcall probe 'requests))))))

(ert-deftest harness-perms-dir-request-always-and-once ()
  (let ((saved nil)
        (harness-allowed-directories nil)
        (a (harness-test-temp-dir))
        (b (harness-test-temp-dir)))
    (harness-perms-test--setup :permission-mode 'auto)
    (harness-perms-test--install-pending)
    (cl-letf (((symbol-function 'harness-save-user-option)
               (lambda (sym value) (set sym value) (push (cons sym value) saved))))
      ;; Always: the directory joins `harness-allowed-directories'.
      (let ((s (harness-perms-test--start-request a "every session needs it")))
        (should (eq 'allow (plist-get (harness-call 'permission/answer "s1" (plist-get (cdr s) :id) "allow-always")
                                      :behavior)))
        (should (string-match-p "every session" (plist-get (harness-test-await (car s)) :reason))))
      (should (equal (list (harness-perms-test--real a)) harness-allowed-directories))
      (should (eq 'harness-allowed-directories (caar saved)))
      ;; A generic "Allow" (once) grants the directory to the session.
      (let ((s (harness-perms-test--start-request b)))
        (should (string-match-p "The agent asks for access to this directory\\."
                                (plist-get (plist-get (cdr s) :payload) :reason)))
        (harness-call 'permission/answer "s1" (plist-get (cdr s) :id) '(:behavior allow :scope once))
        (should (eq 'allow (plist-get (harness-test-await (car s)) :behavior))))
      (should (member (harness-perms-test--real b) (gethash "s1" harness-perms--allowed-dirs)))
      (should (equal (list (harness-perms-test--real a)) harness-allowed-directories)))))

(ert-deftest harness-perms-dir-request-without-a-user ()
  (harness-perms-test--setup :permission-mode 'yolo :non-interactive t)
  (harness-perms-test--install-pending)
  (let ((outside (harness-test-temp-dir)))
    ;; Non-interactive: denied at once with a hint, nothing pending.
    (let ((d (harness-perms-test--decide (harness-perms-test--dir-request outside "need it"))))
      (should (eq 'deny (plist-get d :behavior)))
      (should (plist-get d :final))
      (should (string-match-p "non-interactive" (plist-get d :reason)))
      (should (string-match-p "harness-directories" (plist-get d :hint))))
    (should (null harness-perms-test--pending))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :non-interactive nil))
    ;; A path is required.
    (should (string-match-p "needs the path" (plist-get (harness-perms-test--decide (harness-perms-test--dir-request " "))
                                                        :reason)))
    ;; A directory it can already reach is allowed without asking; nothing is granted.
    (let ((d (harness-perms-test--decide (harness-perms-test--dir-request "sub/dir"))))
      (should (eq 'allow (plist-get d :behavior)))
      (should (string-match-p "already allowed" (plist-get d :reason))))
    (should (null harness-perms-test--pending))
    (should (null (gethash "s1" harness-perms--allowed-dirs)))
    ;; Without a session module nobody can answer.
    (harness-unregister-method 'session/pending-add)
    (let ((d (harness-perms-test--decide (harness-perms-test--dir-request outside))))
      (should (eq 'deny (plist-get d :behavior)))
      (should (string-match-p "no user" (plist-get d :reason))))))

(ert-deftest harness-perms-dir-prompts-name-the-real-directory ()
  "A symbolic link cannot disguise the directory a grant opens."
  (let* ((s (harness-perms-test--setup :permission-mode 'ask))
         (cwd (plist-get s :cwd))
         (target (harness-test-temp-dir))
         (link (expand-file-name "docs" cwd)))
    (make-symbolic-link (directory-file-name target) link)
    (harness-perms-test--install-pending)
    ;; The agent's own request for the link names the target.
    (let ((started (harness-perms-test--start-request "docs" "read the docs")))
      (should (equal (harness-perms-test--real target) (plist-get (plist-get (cdr started) :payload) :dir)))
      (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "deny-once")
      (harness-test-await (car started)))
    ;; So does the jail's prompt for a call through the link.
    (let ((started (harness-perms-test--start "read_file" 'read (expand-file-name "x.txt" link))))
      (should (equal (harness-perms-test--real target) (plist-get (plist-get (cdr started) :payload) :dir)))
      (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "deny-once")
      (harness-test-await (car started)))
    ;; A request for a parent of the working directory says how broad it is.
    (let ((started (harness-perms-test--start-request ".." "look around")))
      (should (string-match-p "contains the working directory"
                              (plist-get (plist-get (cdr started) :payload) :reason)))
      (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "deny-once")
      (harness-test-await (car started)))
    (should (null (gethash "s1" harness-perms--allowed-dirs)))))

;;;; Switching to yolo with a prompt waiting

(defun harness-perms-test--real-session (mode)
  "Load the real modules and create a session in MODE; return its id.
To be used inside `harness-test-with-temp-state'; the caller clears
`harness-sessions' afterwards."
  (harness-test-reset-bus)
  (dolist (m '(store project config provider session tools perms))
    (harness-test-load-module m))
  (clrhash harness-sessions)
  (clrhash harness-perms--waiting)
  (clrhash harness-perms--allowed-dirs)
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :permission-mode mode) :id))

(ert-deftest harness-perms-yolo-switch-accepts-a-waiting-prompt ()
  "Switching a waiting session to yolo answers what yolo would have allowed."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (let ((p (harness-run-filter-async 'permission/decide (list :behavior 'ask)
                                     (harness-perms-test--request "bash" 'exec))))
    (harness-test-wait (lambda () harness-perms-test--pending) 2 "pending")
    (should-not (harness-promise-settled-p p))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode 'yolo))
    (harness-emit 'session/updated "s1" '(:permission-mode yolo))
    (let ((d (harness-test-await p)))
      (should (eq 'allow (plist-get d :behavior)))
      (should (string-match-p "switched to yolo" (plist-get d :reason))))
    (should (null harness-perms-test--pending))
    (should (null (hash-table-keys harness-perms--waiting)))
    ;; Allow once: the answer leaves nothing behind.
    (should (null (gethash "s1" harness-perms--session-rules)))
    (should (equal "p1" (caar harness-perms-test--resolved)))))

(ert-deftest harness-perms-yolo-switch-keeps-what-yolo-would-not-allow ()
  "A standing deny rule and a directory prompt outlive the switch to yolo."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (let* ((outside (harness-test-temp-dir))
         (dir (harness-perms-test--start "read_file" 'read (expand-file-name "x.txt" outside)))
         (tool (harness-perms-test--start "elisp" 'exec
                                          (expand-file-name "f" (plist-get harness-perms-test--session :cwd)))))
    (harness-perms-add-rule "s1" '(:tool "elisp" :behavior deny) 'session)
    (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode 'yolo))
    (harness-emit 'session/updated "s1" '(:permission-mode yolo))
    (accept-process-output nil 0.1)
    ;; The jail asks for a directory in every mode, and the rule beats yolo.
    (should-not (harness-promise-settled-p (car dir)))
    (should-not (harness-promise-settled-p (car tool)))
    (should (= 2 (length harness-perms-test--pending)))
    ;; With the rule gone the tool prompt is accepted; the directory one
    ;; still waits for the user's answer.
    (remhash "s1" harness-perms--session-rules)
    (harness-emit 'session/updated "s1" '(:permission-mode yolo))
    (should (eq 'allow (plist-get (harness-test-await (car tool)) :behavior)))
    (should-not (harness-promise-settled-p (car dir)))
    (harness-call 'permission/answer "s1" (plist-get (cdr dir) :id) "allow-session")
    (should (eq 'allow (plist-get (harness-test-await (car dir)) :behavior)))))

(ert-deftest harness-perms-yolo-switch-runs-a-waiting-call ()
  "Switching a blocked session to yolo runs the call it was waiting on."
  (harness-test-with-temp-state
    (unwind-protect
        (let* ((sid (harness-perms-test--real-session 'ask))
               (ran 0))
          (harness-define-tool "t_exec" :label "Run" :kind 'exec
                               :handler (lambda (_in _ctx) (cl-incf ran) "done"))
          (let ((p (harness-call 'tools/execute sid (list :id "c1" :name "t_exec" :input nil))))
            (harness-test-wait (lambda () (harness-call 'session/pending sid)) 2 "prompt")
            (should (zerop ran))
            (harness-call 'session/update sid :permission-mode 'yolo)
            (let ((r (harness-test-await p)))
              (should-not (plist-get r :is-error))
              (should (equal "done" (plist-get r :content))))
            (should (= 1 ran))
            (should (null (harness-call 'session/pending sid)))
            (should (eq 'idle (plist-get (harness-call 'session/get sid) :status)))
            ;; Allow once: no rule was recorded.
            (should (null (gethash sid harness-perms--session-rules)))))
      (clrhash harness-sessions))))

(ert-deftest harness-perms-yolo-switch-keeps-a-directory-prompt ()
  "Yolo is no permission to widen the jail: the directory prompt waits."
  (harness-test-with-temp-state
    (unwind-protect
        (let* ((sid (harness-perms-test--real-session 'ask))
               (outside (harness-test-temp-dir))
               (ran 0))
          (harness-define-tool "t_read" :label "Read" :kind 'read
                               :paths (lambda (in) (list (plist-get in :path)))
                               :handler (lambda (_in _ctx) (cl-incf ran) "read"))
          (let ((p (harness-call 'tools/execute sid
                                 (list :id "c1" :name "t_read"
                                       :input (list :path (expand-file-name "x.txt" outside))))))
            (harness-test-wait (lambda () (harness-call 'session/pending sid)) 2 "directory prompt")
            (should (plist-get (plist-get (car (harness-call 'session/pending sid)) :payload) :dir))
            (harness-call 'session/update sid :permission-mode 'yolo)
            (accept-process-output nil 0.2)
            (should (zerop ran))
            (should-not (harness-promise-settled-p p))
            (should (harness-call 'session/pending sid))
            (should-not (plist-get (harness-call 'session/get sid) :allowed-dirs))
            ;; The user's answer still grants the directory, and only then
            ;; the call runs.
            (harness-call 'permission/answer
                          sid (plist-get (car (harness-call 'session/pending sid)) :id) "allow-session")
            (should-not (plist-get (harness-test-await p) :is-error))
            (should (= 1 ran))))
      (clrhash harness-sessions))))

(defun harness-perms-test--end-to-end ()
  "Body of `harness-perms-dir-request-end-to-end', with real sessions loaded."
  (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :permission-mode 'auto) :id))
         (outside (harness-test-temp-dir))
         (run (lambda (id path)
                (harness-call 'tools/execute sid (list :id id :name "request_directory_access"
                                                       :input (list :path path :reason "Read the other repository")))))
         (p (funcall run "c1" outside)))
    (harness-test-wait (lambda () (harness-call 'session/pending sid)) 2 "directory prompt")
    (let ((item (car (harness-call 'session/pending sid))))
      (should (eq 'blocked (plist-get (harness-call 'session/get sid) :status)))
      ;; A permission, never a question another agent could answer.
      (should (eq 'permission (plist-get item :kind)))
      (should-not (harness-promise-settled-p p))
      (harness-call 'permission/answer sid (plist-get item :id) "allow-session"))
    (let ((r (harness-test-await p)))
      (should-not (plist-get r :is-error))
      (should (string-match-p "now an allowed directory of this session" (plist-get r :content))))
    (should (equal (list (harness-perms-test--real outside)) (plist-get (harness-call 'session/get sid) :allowed-dirs)))
    (should (null (harness-call 'session/pending sid)))
    (should (eq 'idle (plist-get (harness-call 'session/get sid) :status)))
    ;; A directory it can reach is reported at once.
    (let ((r (harness-test-await (funcall run "c2" (expand-file-name "sub" outside)))))
      (should-not (plist-get r :is-error))
      (should (string-match-p "already accessible: it lies inside .* (granted to this session)" (plist-get r :content))))
    ;; A denial reaches the agent as a denied call with a hint.
    (let ((p (funcall run "c3" (harness-test-temp-dir))))
      (harness-test-wait (lambda () (harness-call 'session/pending sid)) 2 "second prompt")
      (harness-call 'permission/answer sid (plist-get (car (harness-call 'session/pending sid)) :id) "deny-once")
      (let ((r (harness-test-await p)))
        (should (plist-get r :is-error))
        (should (plist-get r :denied))
        (should (string-match-p "\\`Denied: the user denied access to .* Do not ask for it again" (plist-get r :content)))))
    (should (= 1 (length (plist-get (harness-call 'session/get sid) :allowed-dirs))))))

(ert-deftest harness-perms-dir-request-end-to-end ()
  "In auto mode the tool blocks the session on the user, then reports the grant."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (dolist (m '(store project config provider session tools perms))
      (harness-test-load-module m))
    (clrhash harness-sessions)
    (clrhash harness-perms--waiting)
    (clrhash harness-perms--allowed-dirs)
    (unwind-protect
        (harness-perms-test--end-to-end)
      ;; Debounced saves of these sessions must not outlive the store.
      (clrhash harness-sessions))))

(ert-deftest harness-perms-session-tmp-dir-is-allowed-from-the-start ()
  "A session's own temporary directory is one of its roots: listed after
the working directory, never revocable, reachable without a prompt, and
made again when it went missing."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (dolist (m '(store project config provider session tools perms))
      (harness-test-load-module m))
    (clrhash harness-sessions)
    (clrhash harness-perms--waiting)
    (clrhash harness-perms--allowed-dirs)
    (unwind-protect
        (let* ((harness-allowed-directories nil)
               (sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :permission-mode 'ask) :id))
               (tmp (harness-call 'session/tmp-dir sid))
               (dirs (harness-call 'permission/dirs sid)))
          (should tmp)
          (should (equal '(cwd tmp outputs) (mapcar (lambda (e) (plist-get e :source)) dirs)))
          (should (equal tmp (plist-get (nth 1 dirs) :dir)))
          (should-not (plist-get (nth 1 dirs) :revocable))
          (should (string-match-p "temporary directory"
                                  (harness-error-message (should-error (harness-call 'permission/revoke-dir sid tmp)))))
          ;; A read there is allowed in ask mode with nothing asked.
          (harness-define-tool "t_read" :label "Read" :kind 'read :paths (lambda (in) (list (plist-get in :path)))
                               :handler (lambda (in _ctx) (format "read %s" (plist-get in :path))))
          (let ((r (harness-test-await (harness-call 'tools/execute sid (list :id "c1" :name "t_read"
                                                                              :input (list :path (concat tmp "notes.md")))))))
            (should-not (plist-get r :is-error)))
          (should-not (harness-call 'session/pending sid))
          ;; Asking for it grants nothing: it is already there.
          (let ((r (harness-test-await (harness-call 'tools/execute sid
                                                     (list :id "c2" :name "request_directory_access"
                                                           :input (list :path tmp :reason "scratch"))))))
            (should (string-match-p "this session's own temporary directory" (plist-get r :content))))
          (should-not (plist-get (harness-call 'session/get sid) :allowed-dirs))
          ;; Gone (a reboot empties /tmp): the roots bring it back.
          (delete-directory tmp t)
          (should (member tmp (harness-call 'permission/allowed-dirs sid)))
          (should (file-directory-p tmp)))
      (clrhash harness-sessions))))

(ert-deftest harness-perms-denied-scratch-files-go-to-the-tmp-dir ()
  "A session the jail refuses a scratch file elsewhere in /tmp is sent
to its own temporary directory, so it carries on rather than stops."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (dolist (m '(store project config provider session tools perms))
      (harness-test-load-module m))
    (clrhash harness-sessions)
    (clrhash harness-perms--allowed-dirs)
    (unwind-protect
        (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :permission-mode 'yolo
                                             :non-interactive t)
                               :id))
               (tmp (harness-call 'session/tmp-dir sid))
               (run (lambda (tool input)
                      (plist-get (harness-test-await (harness-call 'tools/execute sid (list :id (harness-short-id)
                                                                                           :name tool :input input)))
                                 :content)))
               (scratch (expand-file-name "scratch.txt" temporary-file-directory)))
          (harness-define-tool "t_write" :label "Write" :kind 'write :paths (lambda (in) (list (plist-get in :path)))
                               :handler (lambda (in _ctx) (format "wrote %s" (plist-get in :path))))
          (let ((denied (funcall run "t_write" (list :path scratch))))
            (should (string-match-p "\\`Denied: " denied))
            (should (string-search (concat "use your own temporary directory, " (abbreviate-file-name tmp)) denied)))
          (should (string-search "use your own temporary directory"
                                 (funcall run "request_directory_access"
                                          (list :path temporary-file-directory :reason "scratch"))))
          ;; Only for /tmp: elsewhere the agent may really need that file.
          (should-not (string-search "temporary directory" (funcall run "t_write" (list :path "/etc/harness-x"))))
          (should (equal (concat "wrote " tmp "x") (funcall run "t_write" (list :path (concat tmp "x"))))))
      (clrhash harness-sessions))))

;;;; Patterns a prompt about paths is answered for

(ert-deftest harness-perms-patterns-match-like-globs ()
  "A root or a rule's path is a directory, holding all below it, or a glob."
  (harness-perms-test--setup)
  (let* ((d (harness-perms-test--real (harness-test-temp-dir)))
         (case-fold-search t)           ; file names stay case-sensitive anyway
         (in (lambda (root path) (harness-perms--within-p root (expand-file-name path d)))))
    ;; A directory, with or without its slash, holds itself and what lies below.
    (should (funcall in d "a/b.txt"))
    (should (funcall in (directory-file-name d) "."))
    ;; DIR/** is the same, the directory itself included.
    (should (funcall in (concat d "**") "a/b.txt"))
    (should (funcall in (concat d "**") "."))
    (should-not (harness-perms--within-p (concat d "**") (concat (directory-file-name d) "-evil/x")))
    ;; * stays within a name, ** crosses directories, ? is one character.
    (should (funcall in (concat d "*.org") "todo.org"))
    (should-not (funcall in (concat d "*.org") "sub/todo.org"))
    (should-not (funcall in (concat d "*.org") "todo.ORG"))
    (should (funcall in (concat d "**/*.org") "sub/deep/todo.org"))
    (should (funcall in (concat d "**/*.org") "todo.org"))
    (should (funcall in (concat d "todo.?rg") "todo.org"))
    ;; A path without wildcards holds that file alone when it names one.
    (should (funcall in (concat d "notes/todo.org") "notes/todo.org"))
    (should-not (funcall in (concat d "notes/todo.org") "notes/todo.orgx"))
    ;; Brackets match themselves: a directory may well be called so.
    (let ((photos (file-name-as-directory (expand-file-name "Photos [2024]" d))))
      (make-directory photos)
      (should-not (harness-perms--glob-p photos))
      (should (harness-perms--within-p photos (expand-file-name "a/b.jpg" photos)))
      (should (harness-perms--within-p (concat photos "*.jpg") (expand-file-name "b.jpg" photos)))
      (should-not (harness-perms--within-p (concat d "Photos [0-9]*/**") (expand-file-name "b.jpg" photos)))
      (should (equal photos (harness-perms--grant-form (concat photos "**"))))
      ;; As a working directory, it holds its files.
      (let ((harness-perms-test--session (plist-put (copy-sequence harness-perms-test--session) :cwd photos)))
        (should (eq 'allow (harness-perms-test--behavior "read_file" 'read (expand-file-name "b.jpg" photos))))))
    ;; A glob ending in / holds everything below what it matches, as a
    ;; directory does: so does a directory whose name has a wildcard.
    (should (funcall in (concat d "*/") "sub/deep/x"))
    (let ((odd (file-name-as-directory (expand-file-name "what?" d))))
      (should (harness-perms--within-p odd (expand-file-name "x/y" odd)))
      ;; Granted by its name alone, it is still a directory.
      (make-directory odd)
      (harness-call 'permission/allow-dir "s1" (directory-file-name odd))
      (should (member odd (harness-call 'permission/allowed-dirs "s1"))))
    ;; The directory a pattern starts with is resolved, as paths are.
    (let ((link (expand-file-name "docs" (harness-perms-test--real (harness-test-temp-dir)))))
      (make-symbolic-link (directory-file-name d) link)
      (should (harness-perms--within-p (concat link "/*.md") (expand-file-name "a.md" d)))
      (should (harness-perms--within-p (concat link "/*.md") (concat link "/a.md")))
      (should-not (harness-perms--within-p (concat link "/*.md") (concat link "/a.txt"))))
    ;; A remote pattern matches on its own host only.
    (should (harness-perms--within-p "/ssh:u@box:/srv/*.log" "/ssh:u@box:/srv/a.log"))
    (should-not (harness-perms--within-p "/ssh:u@box:/srv/*.log" "/ssh:u@box:/srv/a/b.log"))
    (should-not (harness-perms--within-p "/ssh:u@box:/srv/*.log" "/ssh:u@other:/srv/a.log"))
    (should-not (harness-perms--within-p "/ssh:u@box:/srv/*.log" "/srv/a.log"))))

(ert-deftest harness-perms-path-prompts-offer-the-directory ()
  "A prompt about a file is answered for everything in its directory unless edited."
  (let* ((s (harness-perms-test--setup :permission-mode 'ask))
         (cwd (harness-perms-test--real (plist-get s :cwd)))
         (outside (harness-perms-test--real (harness-test-temp-dir)))
         (sub (file-name-as-directory (expand-file-name "sub" outside)))
         (pattern-of (lambda (started) (plist-get (plist-get (cdr started) :payload) :pattern))))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :cwd cwd))
    (make-directory sub)
    (harness-perms-test--install-pending)
    (dolist (case (list (list "read_file" 'read (expand-file-name "x.txt" outside) (concat outside "**"))
                        ;; A directory stands for itself.
                        (list "list_dir" 'read (directory-file-name sub) (concat sub "**"))
                        ;; The tool prompt for a write inside the jail.
                        (list "write_file" 'write (expand-file-name "lisp/a.el" cwd) (concat cwd "lisp/**"))
                        (list "bash" 'exec cwd (concat cwd "**"))))
      (pcase-let ((`(,tool ,kind ,path ,pattern) case))
        (let ((started (harness-perms-test--start tool kind path)))
          (should (equal pattern (funcall pattern-of started)))
          (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "deny-once")
          (should (eq 'deny (plist-get (harness-test-await (car started)) :behavior))))))
    ;; Several paths: the directory that holds them all.
    (should (equal (concat outside "")
                   (harness-perms--paths-dir (list (expand-file-name "a/x" outside) (expand-file-name "b/y/z" outside)))))
    ;; A call with no path has no pattern, and its answers hold for the tool.
    (let ((p (harness-run-filter-async 'permission/decide (list :behavior 'ask)
                                       (harness-perms-test--request "elisp" 'exec))))
      (harness-test-wait (lambda () harness-perms-test--pending) 2 "pending")
      (should-not (plist-member (plist-get (car harness-perms-test--pending) :payload) :pattern))
      (harness-call 'permission/answer "s1" (plist-get (car harness-perms-test--pending) :id) "allow-session")
      (harness-test-await p)
      (should (equal '((:tool "elisp" :behavior allow)) (gethash "s1" harness-perms--session-rules))))))

(ert-deftest harness-perms-jail-grants-the-pattern-the-user-edits ()
  "Allow answers to the jail grant the pattern: narrower, wider, or just this call."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (let* ((outside (harness-perms-test--real (harness-test-temp-dir)))
         (parent (file-name-directory (directory-file-name outside)))
         (txt (expand-file-name "notes.txt" outside)))
    ;; Narrower: only the org files there, for the session.
    (let ((s (harness-perms-test--start "read_file" 'read (expand-file-name "todo.org" outside))))
      (should (eq 'continue (harness-call 'permission/answer "s1" (plist-get (cdr s) :id)
                                          (list :option "allow-session" :pattern (concat outside "*.org")))))
      (should (eq 'allow (plist-get (harness-test-await (car s)) :behavior))))
    (should (member (concat outside "*.org") (harness-call 'permission/allowed-dirs "s1")))
    (should (eq 'allow (harness-perms-test--behavior "read_file" 'read (expand-file-name "other.org" outside))))
    (should (null harness-perms-test--pending))
    ;; A pattern that leaves the call's own path out: the call asks again.
    (let ((s (harness-perms-test--start "read_file" 'read txt)))
      (harness-call 'permission/answer "s1" (plist-get (cdr s) :id) (list :option "allow-once" :pattern (concat outside "*.md")))
      (harness-test-wait (lambda () harness-perms-test--pending) 2 "the prompt again")
      (should-not (harness-promise-settled-p (car s)))
      (should (equal (concat outside "**") (plist-get (plist-get (car harness-perms-test--pending) :payload) :pattern)))
      (harness-call 'permission/answer "s1" (plist-get (car harness-perms-test--pending) :id) "deny-once")
      (should (eq 'deny (plist-get (harness-test-await (car s)) :behavior))))
    ;; Once, for a pattern that holds it: this call only.
    (let ((s (harness-perms-test--start "read_file" 'read txt)))
      (harness-call 'permission/answer "s1" (plist-get (cdr s) :id) (list :option "allow-once" :pattern (concat outside "*.txt")))
      (should (eq 'allow (plist-get (harness-test-await (car s)) :behavior))))
    (should-not (member (concat outside "*.txt") (harness-call 'permission/allowed-dirs "s1")))
    ;; Wider: the parent directory; DIR/** is granted as the directory.
    (let ((s (harness-perms-test--start "read_file" 'read txt)))
      (harness-call 'permission/answer "s1" (plist-get (cdr s) :id) (list :option "allow-session" :pattern (concat parent "**")))
      (should (eq 'allow (plist-get (harness-test-await (car s)) :behavior))))
    (should (member parent (harness-call 'permission/allowed-dirs "s1")))
    (should (eq 'allow (harness-perms-test--behavior "read_file" 'read txt)))
    (should (null harness-perms-test--pending))))

(ert-deftest harness-perms-jail-always-deny-records-a-rule ()
  "Always deny on a directory prompt denies its pattern to every tool, without asking."
  (let ((saved nil))
    (harness-perms-test--setup :permission-mode 'ask)
    (harness-perms-test--install-pending)
    (cl-letf (((symbol-function 'harness-save-user-option)
               (lambda (sym value) (set sym value) (push (cons sym value) saved))))
      (let* ((outside (harness-perms-test--real (harness-test-temp-dir)))
             (s (harness-perms-test--start "read_file" 'read (expand-file-name "x.txt" outside))))
        (should (equal harness-perms-dir-options (plist-get (plist-get (cdr s) :payload) :options)))
        (harness-call 'permission/answer "s1" (plist-get (cdr s) :id) "deny-always")
        (let ((d (harness-test-await (car s))))
          (should (eq 'deny (plist-get d :behavior)))
          (should (string-match-p (regexp-quote (abbreviate-file-name (concat outside "**"))) (plist-get d :reason))))
        (should (equal (list (list :path (concat outside "**") :behavior 'deny)) harness-perms-rules))
        (should (eq 'harness-perms-rules (caar saved)))
        ;; The next call there is denied at once, whatever the tool.
        (let ((d (harness-perms-test--decide (harness-perms-test--request "write_file" 'write (expand-file-name "y" outside)))))
          (should (eq 'deny (plist-get d :behavior)))
          (should (plist-get d :final))
          (should (string-match-p "standing rule for .*\\*\\*" (plist-get d :reason))))
        (should (null harness-perms-test--pending))
        ;; So is the agent's own request for the directory.
        (let ((d (harness-perms-test--decide (harness-perms-test--dir-request outside "please"))))
          (should (eq 'deny (plist-get d :behavior)))
          (should (plist-get d :final))
          (should (string-match-p "Do not ask for it again" (plist-get d :hint))))
        (should (null harness-perms-test--pending))
        ;; Elsewhere still asks.
        (let ((other (harness-perms-test--start "read_file" 'read (expand-file-name "z" (harness-test-temp-dir)))))
          (harness-call 'permission/answer "s1" (plist-get (cdr other) :id) "deny-once")
          (harness-test-await (car other)))))))

(ert-deftest harness-perms-dir-request-grants-the-pattern-the-user-edits ()
  "The agent gets what the user granted, which may be narrower than it asked."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (let* ((outside (harness-perms-test--real (harness-test-temp-dir)))
         (api (file-name-as-directory (expand-file-name "api" outside)))
         (result (lambda (started)
                   (harness-perms--dir-request-result (plist-get (harness-test-await (car started)) :input)
                                                      (list :session-id "s1")))))
    (make-directory api)
    ;; A directory below the one asked for.
    (let ((started (harness-perms-test--start-request outside "read the API")))
      (should (equal (concat outside "**") (plist-get (plist-get (cdr started) :payload) :pattern)))
      (should (equal harness-perms-dir-request-options (plist-get (plist-get (cdr started) :payload) :options)))
      (let ((d (harness-call 'permission/answer "s1" (plist-get (cdr started) :id)
                             (list :option "allow-session" :pattern (concat api "**")))))
        (should (eq 'allow (plist-get d :behavior)))
        (should (equal (list :path outside :granted api) (plist-get d :input))))
      (should (member api (harness-call 'permission/allowed-dirs "s1")))
      (should-not (member outside (harness-call 'permission/allowed-dirs "s1")))
      (let ((r (funcall result started)))
        (should-not (plist-get r :is-error))
        (should (string-match-p (format "granted %s instead of %s: it is now allowed for this session"
                                        (regexp-quote (abbreviate-file-name api))
                                        (regexp-quote (abbreviate-file-name outside)))
                                (plist-get r :content)))))
    ;; A glob, written relative to the working directory.
    (let* ((rel (concat (file-name-as-directory (file-relative-name outside (plist-get harness-perms-test--session :cwd)))
                        "*.md"))
           (started (harness-perms-test--start-request outside "the docs")))
      (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) (list :option "allow-session" :pattern rel))
      (let ((r (funcall result started)))
        (should (string-match-p (regexp-quote (concat (abbreviate-file-name outside) "*.md")) (plist-get r :content)))
        (should (string-match-p "the paths it matches" (plist-get r :content))))
      (should (eq 'allow (harness-perms-test--behavior "read_file" 'read (expand-file-name "a.md" outside))))
      (should (null harness-perms-test--pending)))
    ;; The agent cannot claim a grant: a reachable directory reports nothing granted.
    (let ((d (harness-perms-test--decide (list :session harness-perms-test--session :tool harness-perms-dir-tool
                                               :kind 'meta :input (list :path api :granted "/etc/")))))
      (should (eq 'allow (plist-get d :behavior)))
      (should (equal (list :path api) (plist-get d :input))))))

(ert-deftest harness-perms-tool-prompt-remembers-for-a-pattern ()
  "Answers for the session or always hold for the prompt's pattern, not every call of the tool."
  (let* ((saved nil)
         (s (harness-perms-test--setup :permission-mode 'ask))
         (cwd (harness-perms-test--real (plist-get s :cwd)))
         (lisp (file-name-as-directory (expand-file-name "lisp" cwd))))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :cwd cwd))
    (harness-perms-test--install-pending)
    (cl-letf (((symbol-function 'harness-save-user-option)
               (lambda (sym value) (set sym value) (push (cons sym value) saved))))
      (let ((started (harness-perms-test--start "write_file" 'write (expand-file-name "a.el" lisp))))
        (should-not (plist-get (plist-get (cdr started) :payload) :dir))
        (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "allow-session")
        (should (eq 'allow (plist-get (harness-test-await (car started)) :behavior))))
      (should (equal (list (list :tool "write_file" :path (concat lisp "**") :behavior 'allow))
                     (gethash "s1" harness-perms--session-rules)))
      ;; Other files there need no answer; elsewhere, the same tool still asks.
      (should (eq 'allow (harness-perms-test--behavior "write_file" 'write (expand-file-name "b/c.el" lisp))))
      (should (null harness-perms-test--pending))
      (let ((other (harness-perms-test--start "write_file" 'write (expand-file-name "README" cwd))))
        ;; An edited pattern, relative to the working directory, denied for good.
        (harness-call 'permission/answer "s1" (plist-get (cdr other) :id) (list :option "deny-always" :pattern "docs/*.md"))
        (should (eq 'deny (plist-get (harness-test-await (car other)) :behavior))))
      (should (equal (list (list :tool "write_file" :path (concat cwd "docs/*.md") :behavior 'deny)) harness-perms-rules))
      (should (eq 'harness-perms-rules (caar saved)))
      (let ((d (harness-perms-test--decide (harness-perms-test--request "write_file" 'write (expand-file-name "docs/x.md" cwd)))))
        (should (eq 'deny (plist-get d :behavior)))
        (should (string-match-p "standing rule for write_file in .*docs/\\*\\.md" (plist-get d :reason))))
      ;; Not matched: the README again asks.
      (let ((again (harness-perms-test--start "write_file" 'write (expand-file-name "README" cwd))))
        (harness-call 'permission/answer "s1" (plist-get (cdr again) :id) "deny-once")
        (harness-test-await (car again))))))

(ert-deftest harness-perms-path-rules-allow-all-deny-any ()
  "An allow rule with a path needs every path of the call, a deny rule any."
  (let* ((s (harness-perms-test--setup :permission-mode 'ask))
         (cwd (harness-perms-test--real (plist-get s :cwd)))
         (req (lambda (&rest rel) (list :session harness-perms-test--session :tool "write_file" :kind 'write
                                        :paths (mapcar (lambda (r) (expand-file-name r cwd)) rel)))))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :cwd cwd))
    (let ((allow '(:tool "write_file" :path "src/**" :behavior allow))
          (deny '(:path "src/secret/*" :behavior deny)))
      (should (harness-perms--rule-matches-p allow (funcall req "src/a.el" "src/b/c.el")))
      (should-not (harness-perms--rule-matches-p allow (funcall req "src/a.el" "README")))
      (should-not (harness-perms--rule-matches-p allow (funcall req)))
      (should (harness-perms--rule-matches-p deny (funcall req "README" "src/secret/key")))
      (should-not (harness-perms--rule-matches-p deny (funcall req "src/secret/sub/key")))
      ;; The first rule that applies wins, as always.
      (let ((harness-perms-rules (list deny allow)))
        (should (eq 'deny (harness-perms-test--behavior "write_file" 'write (expand-file-name "src/secret/k" cwd))))
        (should (eq 'allow (harness-perms-test--behavior "write_file" 'write (expand-file-name "src/a.el" cwd)))))
      ;; A blank path is no limit.
      (should (harness-perms--rule-matches-p '(:tool "write_file" :path " " :behavior allow) (funcall req "README"))))))

(ert-deftest harness-perms-pattern-grants-list-and-revoke ()
  "A glob grant shows among the directories and can be revoked; one file stays a file."
  (harness-perms-test--setup :permission-mode 'yolo)
  (let* ((outside (harness-perms-test--real (harness-test-temp-dir)))
         (glob (concat outside "*.org"))
         (file (expand-file-name "a.org" outside)))
    (harness-call 'permission/allow-dir "s1" glob)
    (should (member glob (harness-call 'permission/allowed-dirs "s1")))
    (let ((e (cl-find glob (harness-call 'permission/dirs "s1") :key (lambda (e) (plist-get e :dir)) :test #'equal)))
      (should (eq 'session (plist-get e :source)))
      (should (plist-get e :revocable)))
    (should (eq 'allow (harness-perms-test--behavior "read_file" 'read file)))
    (should (eq 'deny (harness-perms-test--behavior "read_file" 'read (expand-file-name "a.txt" outside))))
    (harness-call 'permission/revoke-dir "s1" glob)
    (should-not (member glob (harness-call 'permission/allowed-dirs "s1")))
    (should (eq 'deny (harness-perms-test--behavior "read_file" 'read file)))
    ;; A grant narrowed to one file keeps its name.
    (with-temp-file file (insert "* todo"))
    (harness-call 'permission/allow-dir "s1" file)
    (should (member file (harness-call 'permission/allowed-dirs "s1")))
    (should (eq 'allow (harness-perms-test--behavior "read_file" 'read file)))
    (should (eq 'deny (harness-perms-test--behavior "read_file" 'read (expand-file-name "b.org" outside))))
    (should (equal (concat outside "") (harness-perms--grant-form (concat outside "**"))))
    (should (equal glob (harness-perms--grant-form glob)))
    (should (equal (concat outside "*/**") (harness-perms--grant-form (concat outside "*/**"))))))

(ert-deftest harness-perms-describe-and-reload ()
  (harness-perms-test--setup)
  (harness-define-tool "t_titled" :label "Run" :kind 'exec :subject (lambda (in) (plist-get in :cmd)) :handler #'ignore)
  ;; The tool's label, then what the call is about.
  (should (equal "Run: ls" (harness-perms-describe-request '(:tool "t_titled" :input (:cmd "ls")))))
  ;; A tool nobody registered goes by its name, about the first line of its first string.
  (should (equal "t_unknown: echo hi" (harness-perms-describe-request '(:tool "t_unknown" :input (:command "echo hi\nmore")))))
  ;; Re-running init keeps exactly one handler per stage.
  (harness-perms--init)
  (should (= 7 (length (gethash 'permission/decide harness--filters))))
  (should (memq 'permission/requested (mapcar #'car (harness-events))))
  ;; A hot reload does not run `:init' again for a ready module; loading
  ;; the file still installs the stage that decides directory requests.
  (harness-remove-filter 'permission/decide #'harness-perms--dir-request)
  (harness-test-load-module 'perms)
  (should (harness-module-ready-p 'perms))
  (should (rassq #'harness-perms--dir-request (gethash 'permission/decide harness--filters)))
  (should (= 7 (length (gethash 'permission/decide harness--filters)))))

;;;; Commands the sandbox makes destructive

(defvar harness-sandbox-policy)

(defun harness-perms-test--bash (command)
  "Return the permission request of a bash call running COMMAND."
  (list :session harness-perms-test--session :tool "bash" :kind 'exec
        :input (list :command command) :paths (list (plist-get harness-perms-test--session :cwd))
        :call-id (harness-short-id)))

(ert-deftest harness-perms-sandbox-guard-is-final ()
  "What the sandbox refuses is denied in every mode; the rest goes on."
  (let ((s (harness-perms-test--setup :permission-mode 'yolo :worktree "/repo/.worktrees/own/"))
        (seen nil))
    (harness-register-method 'sandbox/check-command
                             (lambda (cwd command &optional own)
                               (push (list cwd command own) seen)
                               (when (string-match-p "prune" command)
                                 (list :reason "refused: use worktree/prune" :hint "never prune"))))
    (let ((d (harness-perms-test--decide (harness-perms-test--bash "git worktree prune"))))
      (should (eq 'deny (plist-get d :behavior)))
      (should (plist-get d :final))
      (should (equal "refused: use worktree/prune" (plist-get d :reason)))
      (should (equal "never prune" (plist-get d :hint))))
    ;; The sandbox learns where the command runs and the session's worktree.
    (should (equal (list (plist-get s :cwd) "git worktree prune" "/repo/.worktrees/own/") (car seen)))
    ;; A standing rule allowing bash does not help either.
    (harness-perms-add-rule "s1" '(:tool "bash" :behavior allow) 'session)
    (should (eq 'deny (plist-get (harness-perms-test--decide (harness-perms-test--bash "git worktree prune")) :behavior)))
    ;; Other commands go on: yolo allows them.
    (should (eq 'allow (plist-get (harness-perms-test--decide (harness-perms-test--bash "git status")) :behavior)))
    ;; Calls that run no shell command are not looked at.
    (setq seen nil)
    (should (eq 'allow (harness-perms-test--behavior "read_file" 'read (expand-file-name "f" (plist-get s :cwd)))))
    (should-not seen)
    ;; A guard that fails lets the chain decide.
    (harness-register-method 'sandbox/check-command (lambda (&rest _) (error "Broken")))
    (should (eq 'allow (plist-get (harness-perms-test--decide (harness-perms-test--bash "git status")) :behavior)))))

(ert-deftest harness-perms-sandbox-guard-end-to-end ()
  "In a sandbox, the bash tool never runs the cleanup that unregistered every worktree."
  (harness-perms-test--setup :permission-mode 'yolo)
  (harness-test-load-module 'sandbox)
  (harness-test-load-module 'tools-shell)
  (unwind-protect
      (let ((harness-sandbox-policy 'preferred)
            (ran nil))
        (cl-letf (((symbol-function 'executable-find)
                   (lambda (name &optional _remote) (and (equal name "bwrap") "/usr/bin/bwrap"))))
          (harness-sandbox-detect))
        (cl-letf (((symbol-function 'harness-run-command) (lambda (&rest _) (setq ran t) (harness-resolved nil))))
          (let ((r (harness-test-await
                    (harness-call 'tools/execute "s1"
                                  (list :id "c1" :name "bash"
                                        :input (list :command "git worktree remove --force .test-logs/base && git worktree prune"))))))
            (should (plist-get r :is-error))
            (should (plist-get r :denied))
            (should (string-match-p "\\`Denied: `git worktree prune` is refused in the sandbox" (plist-get r :content)))
            (should (string-match-p "worktree/prune" (plist-get r :content)))))
        (should-not ran))
    (harness-sandbox-detect)))

(ert-deftest harness-perms-rules-type-names-every-key ()
  "The settings page offers each part of a standing rule by name."
  (require 'harness-test-helpers)
  (let ((type (cadr (get 'harness-perms-rules 'custom-type))))
    (should (equal '(:tool :kind :path :behavior) (harness-test-option-keys type)))
    (harness-test-check-record-type type)
    (should (harness-test-fits-p type '(:tool "web_search" :behavior deny)))
    (should (harness-test-fits-p type '(:kind read :behavior allow)))
    (should (harness-test-fits-p type '(:tool "write_file" :path "/home/u/proj/lisp/**" :behavior allow)))
    (should (harness-test-fits-p type '(:behavior "deny")))
    (should (harness-test-fits-p (get 'harness-perms-rules 'custom-type)
                                 '((:tool "bash" :kind exec :behavior deny) (:behavior allow))))))

(provide 'harness-perms-test)
;;; harness-perms-test.el ends here
