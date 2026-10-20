;;; harness-perms-test.el --- Tests for the permission chain  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-providers)
(defvar harness-allowed-directories)
(defvar harness-perms-rules)

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
  (clrhash harness-perms--turn-dirs)
  (clrhash harness-perms--session-rules)
  (clrhash harness-perms--waiting)
  (clrhash harness-perms--judging)
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

(ert-deftest harness-perms-review-tools-need-no-approval ()
  "A task's agent answers a thread of its review without asking first.
review_threads and review_comment only read and write the threads the
user reads; asking about each answer would keep an unattended agent
from answering at all.  A standing rule still beats them."
  (harness-perms-test--setup :permission-mode 'ask :non-interactive t)
  (dolist (tool '("review_threads" "review_comment"))
    (should (member tool harness-perms--auto-allow-tools))
    (should (eq 'allow (harness-perms-test--behavior tool 'meta))))
  (let ((harness-perms-rules '((:tool "review_comment" :behavior deny))))
    (should (eq 'deny (harness-perms-test--behavior "review_comment" 'meta)))
    (should (eq 'allow (harness-perms-test--behavior "review_threads" 'meta)))))

(ert-deftest harness-perms-extra-auto-allow-tools-need-no-approval ()
  "A module outside the harness may say a tool of its own needs no approval.
It adds the tool to `harness-perms-extra-auto-allow-tools', as this
repository's plugin does open_harness; the tool is then allowed in
every mode, and `permission/rules' lists it with the harness's own.
A standing rule still beats it."
  (harness-perms-test--setup :permission-mode 'ask)
  ;; Not listed, the mode leaves it to be asked.
  (should (eq 'ask (plist-get (harness-perms--mode-decision
                               (list :behavior 'ask) (harness-perms-test--request "my_tool" 'exec))
                              :behavior)))
  (let ((harness-perms-extra-auto-allow-tools '("my_tool")))
    (should (eq 'allow (harness-perms-test--behavior "my_tool" 'exec)))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode 'auto))
    (should (eq 'allow (harness-perms-test--behavior "my_tool" 'exec)))
    (should (member "my_tool" (plist-get (harness-call 'permission/rules (plist-get harness-perms-test--session :id))
                                         :auto-allow)))
    (let ((harness-perms-rules '((:tool "my_tool" :behavior deny))))
      (should (eq 'deny (harness-perms-test--behavior "my_tool" 'exec))))))

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

(defun harness-perms-test--record-jobs ()
  "Stand in for the internal sessions the judge's calls are recorded as.
Return a function giving the job and the parent of each call, newest
first, as `provider/complete' passed them to `session/internal-start'."
  (let ((jobs nil))
    (harness-register-method 'session/internal-start
                             (lambda (&rest plist)
                               (push (list (plist-get plist :job) (plist-get plist :parent-id)) jobs)
                               (format "internal-%d" (length jobs))))
    (harness-register-method 'session/internal-finish #'ignore)
    (lambda () jobs)))

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

(ert-deftest harness-perms-judge-deny-asks-the-user-in-auto-mode ()
  "A judge denial in an interactive auto session is put to the user.
The judge is a cheap model and can be wrong: the user, who is present,
is asked about the call and can allow it.  Switching to yolo used to be
the only way past a denial."
  (harness-perms-test--setup :permission-mode 'auto)
  (harness-perms-test--install-pending)
  (harness-define-tool "t_edit" :label "Edit" :kind 'write :description "Edits a file." :handler #'ignore)
  (harness-perms-test--judge-provider
   '((:type text :delta "{\"decision\":\"deny\",\"reason\":\"it rewrites the project settings\"}")
     (:type done :stop-reason end-turn)))
  (let* ((harness-perms-auto-model "judge:x")
         (p (harness-run-filter-async 'permission/decide (list :behavior 'ask)
                                      (harness-perms-test--request "t_edit" 'write)))
         (pending nil))
    (harness-test-wait (lambda () harness-perms-test--pending) 2 "the judge's prompt")
    (setq pending (car harness-perms-test--pending))
    (should (eq 'permission (plist-get pending :kind)))
    (should (equal "t_edit" (plist-get (plist-get pending :payload) :tool)))
    (should (equal harness-perms-options (plist-get (plist-get pending :payload) :options)))
    (should (string-match-p "The permission judge would deny this call: it rewrites the project settings"
                            (plist-get (plist-get pending :payload) :reason)))
    ;; The user allows it: the call runs.
    (let ((d (harness-call 'permission/answer "s1" (plist-get pending :id) "allow-once")))
      (should (eq 'allow (plist-get d :behavior)))
      (should (string-match-p "allowed by the user" (plist-get d :reason))))
    (should (eq 'allow (plist-get (harness-test-await p) :behavior)))))

(ert-deftest harness-perms-judge-deny-stands-when-nobody-can-answer ()
  "Without a user to ask, the judge's denial is the decision.
A non-interactive session takes it and is steered to another approach;
an interactive one with nobody able to answer is denied too."
  (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
  (harness-define-tool "t_exec2" :label "Run" :kind 'exec :handler (lambda (_in _ctx) "ran"))
  (let ((prompts (harness-perms-test--prompts)))
    (harness-perms-test--judge-provider
     '((:type text :delta "{\"decision\":\"deny\",\"reason\":\"it force pushes to the shared remote\"}")
       (:type done :stop-reason end-turn)))
    (let* ((harness-perms-auto-model "judge:x")
           (r (harness-test-await (harness-call 'tools/execute "s1"
                                                (list :id "c1" :name "t_exec2" :input '(:command "x"))))))
      (should (plist-get r :denied))
      (should (string-match-p "\\`Denied: it force pushes to the shared remote" (plist-get r :content))))
    ;; The agent was told to find another way.
    (should (equal (list (cons "s1" (format harness-perms-steering-text "t_exec2"))) (funcall prompts)))
    ;; An interactive session is asked instead, and nobody else's business.
    (let ((verdict (list :behavior 'deny :reason "it force pushes to the shared remote"
                         :hint harness-perms-judge-deny-hint)))
      (should (eq 'deny (plist-get (harness-perms--judge-decision verdict harness-perms-test--session)
                                   :behavior)))
      ;; Interactive with nobody able to answer: the denial stands, with
      ;; the judge's reason, rather than turning into a dead end.
      (should (equal verdict (harness-perms--judge-decision
                              verdict (plist-put (copy-sequence harness-perms-test--session)
                                                 :non-interactive nil))))
      (harness-perms-test--install-pending)
      (let* ((d (harness-perms--judge-decision
                 verdict (plist-put (copy-sequence harness-perms-test--session) :non-interactive nil)))
             (prompt (harness-perms--judge-prompt-reason d)))
        (should (eq 'ask (plist-get d :behavior)))
        (should (plist-get d :judge-deny))
        (should (equal "it force pushes to the shared remote" (plist-get d :reason)))
        (should (equal (concat "The permission judge would deny this call: it force pushes to the shared remote")
                       prompt)))
      ;; A call the judge allowed is never put to the user; one denied
      ;; while the user is away is not either.
      (should (eq 'allow (plist-get (harness-perms--judge-decision
                                     (list :behavior 'allow :reason "fine") harness-perms-test--session)
                                    :behavior)))
      (should-not (harness-perms--judge-prompt-reason (list :behavior 'ask))))))

(ert-deftest harness-perms-auto-model-takes-the-providers-simple-tier ()
  "`harness-perms-auto-model' `auto' judges with the session provider's simple tier.
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
      :tiers '(:simple "mid")
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
  (let* ((jobs (harness-perms-test--record-jobs))
         (requests (harness-perms-test--scripted-judge
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
                   (plist-get (car (funcall requests)) :max-tokens)))
    ;; Each call is recorded as an internal session of the session asking.
    (should (equal '(("Permission judge (retry)" "s1") ("Permission judge" "s1")) (funcall jobs)))))

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

(ert-deftest harness-perms-judge-prompt-keeps-harness-tools-ordinary ()
  "The judge is told the harness's own tools are ordinary work.
It used to refuse sub-agents, messages to other sessions and session
control as changes to the agent's permissions, which stopped the
harness's own workflows (spawning help, answering a parent session)."
  (harness-perms-test--setup :permission-mode 'auto)
  (dolist (phrase '("sub-agents" "other sessions of the harness" "task board"))
    (should (string-search phrase harness-perms--judge-system))))

(ert-deftest harness-perms-judge-sees-a-cut-input-as-cut ()
  "A long input is cut, and the judge is told the harness cut it.
It used to be cut with a trailing ellipsis and nothing else, and the
judge read that as the agent's own incomplete value: \"the replacement
string is truncated ... that would corrupt the file\".  A judge must
weigh what the call would do, never whether a value looks complete."
  (harness-perms-test--setup :permission-mode 'auto)
  (let* ((short (harness-perms--judge-input (list :path "a.el" :new_string "x")))
         (long-text (make-string (1+ harness-perms--judge-input-chars) ?x))
         (long (harness-perms--judge-input (list :path "a.el" :new_string long-text))))
    ;; A short input goes in whole and says nothing about cutting.
    (should (string-prefix-p "Input (JSON):\n" short))
    (should-not (string-search "cut the rest" short))
    (should-not (string-search "…" short))
    ;; A long one is marked as cut, and its value is not elided to look
    ;; like the agent's own text.
    (should (string-search "the harness shows its first" long))
    (should (string-search "cut the rest" long))
    (should-not (string-search "…" long))
    (should (string-search "the call is not missing anything" long))
    ;; What is shown is the first characters of the input, not an
    ;; ellipsis standing for the rest.
    (should (string-suffix-p (substring (harness-json-encode-text
                                         (list :path "a.el" :new_string long-text))
                                        0 harness-perms--judge-input-chars)
                             long))))

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

;;;; Read-only cloud commands

(defun harness-perms-test--exec (command)
  "Decide COMMAND, a shell command, and return the decision."
  (harness-perms-test--decide
   (list :session harness-perms-test--session :tool "bash" :kind 'exec
         :input (list :command command) :call-id (harness-short-id))))

(ert-deftest harness-perms-read-only-cloud-commands-need-no-judge ()
  "A read-only cloud query must not reach the auto-mode judge.
The judge runs on the cheapest model, sees the call alone and read a
cloud service outside the allowed roots as egress: it denied an
uptime-check read as sending email to a third party and `gsutil ls' as
sending credentials off the machine.  The mode stage allows them in
`auto' mode and for a session the user left non-interactive, before the
judge would be asked."
  (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
  (let* ((probe (harness-perms-test--judge-provider
                 '((:type text :delta "{\"decision\":\"deny\",\"reason\":\"it emails a third party\"}")
                   (:type done :stop-reason end-turn))))
         (harness-perms-auto-model "judge:x"))
    (dolist (command '("gcloud monitoring uptime list-configs"
                       "gcloud monitoring uptime list-configs --project my-proj"
                       "gcloud compute instances list --format=json --project=my-proj"
                       "gcloud projects get-iam-policy my-proj"
                       "gcloud config get-value project"
                       "gcloud logging read --limit=10"
                       "gcloud iam service-accounts list"
                       "gsutil ls gs://my-bucket"
                       "gsutil ls -l gs://my-bucket"
                       "gsutil cat gs://my-bucket/log.txt"
                       "gsutil stat gs://my-bucket/object"
                       "gcloud compute instances list && gcloud projects list"
                       ;; A here-document's body is data, not commands:
                       ;; what it says does not change what runs.
                       "gcloud compute instances list <<EOF\ngcloud rm\nEOF"))
      (let ((d (harness-perms-test--exec command)))
        (should (eq 'allow (plist-get d :behavior)))
        (should (string-match-p "cloud" (plist-get d :reason)))))
    ;; The judge never saw any of them.
    (should (null (funcall probe 'requests)))
    ;; An interactive auto session allows them too, and the judge still sees nothing.
    (setq harness-perms-test--session
          (plist-put harness-perms-test--session :non-interactive nil))
    (should (eq 'allow (plist-get (harness-perms-test--exec "gsutil ls gs://my-bucket") :behavior)))
    (should (null (funcall probe 'requests)))))

(ert-deftest harness-perms-cloud-writes-and-logins-still-go-to-the-judge ()
  "A cloud command that is no obvious read is left to the judge.
Writes, deletions, rsyncs, interactive logins and a credential printed
are never allowed by the mode stage, and neither is a read hidden after
another program, or a write verb that looks like a read operand."
  (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
  (let* ((probe (harness-perms-test--judge-provider
                 '((:type text :delta "{\"decision\":\"deny\",\"reason\":\"it changes the cloud\"}")
                   (:type done :stop-reason end-turn))))
         (harness-perms-auto-model "judge:x")    ; the judge is consulted
         (commands '("gcloud config set project my-proj"
                     "gcloud compute instances delete my-instance"
                     "gcloud monitoring uptime delete my-check"
                     "gcloud auth login"
                     "gcloud auth print-access-token"
                     "gcloud container clusters get-credentials my-cluster"
                     "gcloud compute ssh my-instance"
                     "gsutil rm gs://my-bucket/object"
                     "gsutil cp gs://my-bucket/object ."
                     "gsutil rsync -r gs://a gs://b"
                     "gcloud storage cp list.txt gs://my-bucket/"
                     "gcloud compute instances clone list-instance src"
                     "gcloud compute instances simulate-maintenance-event list-instance"
                     "gsutil ls gs://my-bucket && rm -rf /"
                     "gcloud compute instances list $(rm -rf /)"
                     "sudo gcloud compute instances list"
                     "gcloud compute instances list | jq ."
                     "gcloud --project p compute instances list"
                     "gcloud components install"
                     "gsutil iam ch user:x:objectViewer gs://b")))
    (dolist (command commands)
      (let ((request (list :session harness-perms-test--session :tool "bash" :kind 'exec
                           :input (list :command command) :call-id (harness-short-id))))
        (should-not (harness-perms--read-only-cloud-p request))
        (should (eq 'deny (plist-get (harness-perms-test--decide request) :behavior)))))
    ;; Every command that names no outside path reached the judge.
    (should (funcall probe 'requests))))

(ert-deftest harness-perms-cloud-reads-still-ask-a-present-user ()
  "A user who is present and a mode that asks still get their prompt.
The allow is exactly where the judge would rule (auto mode, or the user
away); ask mode asks the user, as for every other shell command."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (let ((p (harness-run-filter-async
            'permission/decide (list :behavior 'ask)
            (list :session harness-perms-test--session :tool "bash" :kind 'exec
                  :input (list :command "gsutil ls gs://my-bucket") :call-id "c-cloud"))))
    (harness-test-wait (lambda () harness-perms-test--pending) 2 "the prompt")
    (should-not (harness-promise-settled-p p))
    (should (equal "bash" (plist-get (plist-get (car harness-perms-test--pending) :payload) :tool)))
    (harness-call 'permission/answer "s1" (plist-get (car harness-perms-test--pending) :id) "deny-once")
    (should (eq 'deny (plist-get (harness-test-await p) :behavior)))))

(ert-deftest harness-perms-judge-prompt-names-read-only-cloud-work ()
  "The judge is told read-only cloud queries are ordinary work.
It reads the call alone, so its prompt says that authenticating to a
service and reading the user's own resources is not egress and names
the commands it must not deny, along with the writes and logins it
still must."
  (harness-perms-test--setup :permission-mode 'auto)
  (dolist (part '("gcloud monitoring uptime list-configs"
                  "gsutil ls"
                  "kubectl get pods"
                  "not sending secrets off the machine"
                  "auth print-access-token"
                  "sending secrets or private data off the machine"))
    (should (string-search part harness-perms--judge-system))))

;;;; The rules Claude Code's own auto mode follows

(defun harness-perms-test--call-with-claude-settings (files fn &optional profile)
  "Call FN with Claude Code's settings made of FILES and nothing else.
FILES maps names to the JSON text of files under one root: config/ is
Claude Code's configuration directory ($CLAUDE_CONFIG_DIR), system/
the system directory of its managed settings files, and project/ a
project.  PROFILE stands for the settings of the macOS configuration
profile.  FN is called with the root.  No real settings are read."
  (let* ((root (harness-test-temp-dir))
         (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" (expand-file-name "config" root))
                                    process-environment))
         (harness-perms-claude-auto-mode t))
    (dolist (dir '("config/" "system/" "project/"))
      (make-directory (expand-file-name dir root) t))
    (pcase-dolist (`(,name . ,text) files)
      (let ((path (expand-file-name name root)))
        (make-directory (file-name-directory path) t)
        (with-temp-file path (insert text))))
    (cl-letf (((symbol-function 'harness-perms--claude-system-dir)
               (lambda () (file-name-as-directory (expand-file-name "system" root))))
              ((symbol-function 'harness-perms--claude-profile-settings)
               (lambda () profile)))
      (unwind-protect (funcall fn root)
        (delete-directory root t)))))

(ert-deftest harness-perms-claude-auto-mode-rules-are-the-ones-claude-code-reads ()
  "The judge reads the autoMode rules Claude Code's auto mode reads.
They come from the managed settings Claude Code applies and from the
user's settings.json, combined list by list as Claude Code combines
them: the managed entries first, managed-settings.json before the
files of managed-settings.d in alphabetical order, then the user's,
without the \"$defaults\" marker, blank entries or duplicates.  A
project's .claude/settings.json and settings.local.json are never
read, as Claude Code never reads them: whoever writes the repository
would be writing the judge's exceptions."
  (harness-perms-test--setup :permission-mode 'auto)
  (harness-perms-test--call-with-claude-settings
   '(("system/managed-settings.json"
      . "{\"autoMode\": {\"environment\": [\"$defaults\", \"Source control: github.example.com/acme-corp\"],
                         \"hard_deny\": [\"Never send repository contents to third-party code-review APIs\"]}}")
     ("system/managed-settings.d/20-security.json" . "{\"autoMode\": {\"soft_deny\": [\"Never run terraform apply\"]}}")
     ("system/managed-settings.d/10-buckets.json"
      . "{\"autoMode\": {\"environment\": [\"Trusted cloud buckets: s3://acme-builds\"]}}")
     ("system/managed-settings.d/.hidden.json" . "{\"autoMode\": {\"allow\": [\"A hidden file\"]}}")
     ("system/managed-settings.d/notes.txt" . "{\"autoMode\": {\"allow\": [\"No .json file\"]}}")
     ("config/settings.json"
      . "{\"model\": \"opus\",
          \"autoMode\": {\"environment\": [\"Source control: github.example.com/acme-corp\", \"  \", 7,
                                           \"Trusted internal domains: *.corp.example.com\"],
                         \"allow\": [\"$defaults\", \"Deploying to the staging namespace is allowed\"],
                         \"classifyAllShell\": true}}")
     ("project/.claude/settings.json" . "{\"autoMode\": {\"allow\": [\"Whatever the repository says\"]}}")
     ("project/.claude/settings.local.json" . "{\"autoMode\": {\"allow\": [\"Anything at all\"]}}"))
   (lambda (root)
     (let ((default-directory (expand-file-name "project/" root)))
       (setq harness-perms-test--session (plist-put harness-perms-test--session :cwd default-directory))
       (should (equal '(:environment ("Source control: github.example.com/acme-corp"
                                      "Trusted cloud buckets: s3://acme-builds"
                                      "Trusted internal domains: *.corp.example.com")
                        :hard_deny ("Never send repository contents to third-party code-review APIs")
                        :soft_deny ("Never run terraform apply")
                        :allow ("Deploying to the staging namespace is allowed"))
                      (harness-perms-claude-auto-mode-rules))))))
  ;; Claude Code's configuration directory is $CLAUDE_CONFIG_DIR, else ~/.claude.
  (let ((process-environment (cons "CLAUDE_CONFIG_DIR=/opt/claude-config" process-environment)))
    (should (equal "/opt/claude-config/" (harness-perms--claude-config-dir))))
  (let ((process-environment (cons "CLAUDE_CONFIG_DIR" process-environment)))
    (should (equal (expand-file-name "~/.claude/") (harness-perms--claude-config-dir)))))

(ert-deftest harness-perms-claude-managed-sources-rank-as-in-claude-code ()
  "Of the managed sources the judge reads the ones Claude Code applies.
By default that is the highest-ranked source that delivers a policy
key: the server-managed settings Claude Code caches, then the macOS
configuration profile, then the managed settings files.  A source
with only control keys or metadata delivers none, and a lower
source's autoMode never counts when a higher one delivers a policy,
whatever it is.  When the highest-ranked source that says anything
sets managedSourcesBehavior to \"merge\", every source with a policy
key adds its entries; a lower source cannot ask for that."
  (harness-perms-test--setup :permission-mode 'auto)
  (let ((remote "{\"$checksum\": \"abc\", \"autoMode\": {\"environment\": [\"Remote: acme\"]}}")
        (file "{\"autoMode\": {\"environment\": [\"File: acme\"]}}")
        (profile '(:autoMode (:environment ("Profile: acme")))))
    (cl-flet ((environment (files &optional profile)
                (let (out)
                  (harness-perms-test--call-with-claude-settings
                   files
                   (lambda (_root) (setq out (plist-get (harness-perms-claude-auto-mode-rules) :environment)))
                   profile)
                  out)))
      ;; The first source with a policy wins.
      (should (equal '("Remote: acme")
                     (environment `(("config/remote-settings.json" . ,remote) ("system/managed-settings.json" . ,file))
                                  profile)))
      (should (equal '("Profile: acme") (environment `(("system/managed-settings.json" . ,file)) profile)))
      (should (equal '("File: acme") (environment `(("system/managed-settings.json" . ,file)))))
      ;; Control keys and metadata are no policy.
      (should (equal '("File: acme")
                     (environment `(("config/remote-settings.json"
                                     . "{\"$schema\": \"x\", \"managedSourcesBehavior\": \"first-wins\", \"model\": null}")
                                    ("system/managed-settings.json" . ,file)))))
      ;; A policy without autoMode still wins over a lower one with it.
      (should-not (environment `(("config/remote-settings.json" . "{\"permissions\": {\"deny\": [\"Bash(curl *)\"]}}")
                                 ("system/managed-settings.json" . ,file))))
      ;; Merging, asked for by the highest-ranked source, with or without a policy of its own.
      (should (equal '("Remote: acme" "Profile: acme" "File: acme")
                     (environment `(("config/remote-settings.json"
                                     . "{\"managedSourcesBehavior\": \"merge\", \"autoMode\": {\"environment\": [\"Remote: acme\"]}}")
                                    ("system/managed-settings.json" . ,file))
                                  profile)))
      (should (equal '("Profile: acme" "File: acme")
                     (environment `(("config/remote-settings.json" . "{\"managedSourcesBehavior\": \"merge\"}")
                                    ("system/managed-settings.json" . ,file))
                                  profile)))
      ;; Asked for by a lower source, it is not done.
      (should (equal '("Remote: acme")
                     (environment `(("config/remote-settings.json" . ,remote)
                                    ("system/managed-settings.json"
                                     . "{\"managedSourcesBehavior\": \"merge\", \"autoMode\": {\"environment\": [\"File: acme\"]}}"))))))))

(ert-deftest harness-perms-judge-follows-claude-auto-mode-rules ()
  "The judge is given Claude Code's autoMode rules, after its own.
Claude Code's auto mode trusts what the organization's environment
names, so pushing to its repositories or uploading to its buckets is
routine there.  A judge without those rules takes that for sending
private data off the machine, which is stricter than Claude Code
with the same settings.  Each list comes under what it means to
Claude Code.  The judge's own prompt comes first, word for word, and
no entry lifts its rules.  Writing such rules counts as the agent
widening its own permissions."
  (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
  (harness-perms-test--call-with-claude-settings
   '(("system/managed-settings.json"
      . "{\"autoMode\": {\"environment\": [\"$defaults\", \"Source control: github.example.com/acme-corp\"],
                         \"hard_deny\": [\"Never send repository contents to third-party code-review APIs\"],
                         \"soft_deny\": [\"Never run terraform apply\"],
                         \"allow\": [\"Writing to s3://acme-scratch/ is allowed:\\nan ephemeral bucket\"]}}"))
   (lambda (_root)
     (let* ((requests (harness-perms-test--scripted-judge
                       '(((:type text :delta "{\"decision\":\"allow\",\"reason\":\"the organization's own repository\"}")
                          (:type done :stop-reason end-turn)))))
            (harness-perms-auto-model "judge:x")
            (d (harness-perms-test--decide
                (list :session harness-perms-test--session :tool "bash" :kind 'exec
                      :input '(:command "git push git@github.example.com:acme-corp/tools.git HEAD")
                      :call-id "c1")))
            (system (plist-get (car (funcall requests)) :system)))
       (should (eq 'allow (plist-get d :behavior)))
       (should (equal system (harness-perms--judge-system-prompt)))
       (should (string-prefix-p (concat harness-perms--judge-system "\n\nRules from Claude Code's settings.") system))
       (should (string-search "lift none\nof them" system))
       (dolist (part '("\nEnvironment: what counts as the organization's own infrastructure"
                       "not sending private data off\nthe machine"
                       "Secrets still go nowhere but the service they belong to"
                       "do not name is judged by the rules above alone"
                       "\n- Source control: github.example.com/acme-corp\n"
                       "\nHard deny: deny every call one of these describes, whatever else applies.\n- Never send repository contents to third-party code-review APIs\n"
                       "\nSoft deny: deny every call one of these describes, unless an allow entry\ncovers it.\n- Never run terraform apply\n"
                       "\nAllow: exceptions to the soft deny entries, and to nothing else.\n- Writing to s3://acme-scratch/ is allowed:\n  an ephemeral bucket"))
         (should (string-search part system)))
       (should-not (string-search "$defaults" system)))))
  ;; Its hard rules are all there, and writing the rules widens the agent's permissions.
  (dolist (rule '("deleting or overwriting existing data outside the allowed roots"
                  "force pushes, deleting remote branches" "sending secrets or private data off the machine"
                  "changing system configuration" "widening the agent's own permissions"
                  "writing autoMode rules into Claude"))
    (should (string-search rule harness-perms--judge-system))))

(ert-deftest harness-perms-judge-without-claude-auto-mode-rules-keeps-its-prompt ()
  "Without autoMode rules the judge's prompt is its own, word for word.
So it is with no settings at all, with lists that are empty or only
hold \"$defaults\", with settings that cannot be read or are of the
wrong shape, and with `harness-perms-claude-auto-mode' off."
  (harness-perms-test--setup :permission-mode 'auto)
  (let ((unchanged (lambda (files)
                     (harness-perms-test--call-with-claude-settings
                      files
                      (lambda (_root)
                        (should-not (harness-perms-claude-auto-mode-rules))
                        (should (equal harness-perms--judge-system (harness-perms--judge-system-prompt))))))))
    (funcall unchanged nil)
    (funcall unchanged
             '(("config/settings.json"
                . "{\"autoMode\": {\"environment\": [\"$defaults\"], \"allow\": [], \"soft_deny\": \"Never this\",
                                   \"hard_deny\": {\"a\": \"Never that\"}},
                    \"permissions\": {\"allow\": [\"Bash(make *)\"]}}")
               ("config/remote-settings.json" . "[\"not\", \"an\", \"object\"]")
               ("system/managed-settings.json" . "{\"autoMode\": ")
               ("system/managed-settings.d/10-x.json" . "{\"autoMode\": \"everything\"}")))
    (harness-perms-test--call-with-claude-settings
     '(("config/settings.json" . "{\"autoMode\": {\"environment\": [\"Source control: github.example.com/acme-corp\"]}}"))
     (lambda (_root)
       (should (harness-perms-claude-auto-mode-rules))
       (let ((harness-perms-claude-auto-mode nil))
         (should-not (harness-perms-claude-auto-mode-rules))
         (should (equal harness-perms--judge-system (harness-perms--judge-system-prompt))))))))

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

(ert-deftest harness-perms-corporate-mode-searches-the-web ()
  ;; Corporate mode leaves web search on: an unattended task session
  ;; searches with web_search or its provider's own search, as the rules
  ;; for web_search decide, standing rules included.  web_fetch is
  ;; refused before the chain, so not even the judge is asked about it.
  (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
  (harness-test-load-module 'tools-web)
  (let ((probe (harness-perms-test--judge-provider
                '((:type text :delta "{\"decision\":\"allow\",\"reason\":\"fine\"}")
                  (:type done :stop-reason end-turn))))
        (harness-perms-auto-model "judge:small")
        (harness-corporate-mode t)
        (harness-websearch-providers nil)
        (harness-websearch-provider 'fake))
    (harness-register-method 'agent/prompt (lambda (&rest _) (harness-resolved nil)))
    (harness-websearch-register-provider
     'fake (lambda (query _count) (list (list :title (concat "About " query) :url "https://example.org/"))))
    (cl-letf (((symbol-function 'harness-http-request)
               (lambda (&rest _) (error "Nothing may reach the web"))))
      (let ((r (harness-test-await (harness-call 'tools/execute "s1"
                                                 '(:id "c1" :name "web_search" :input (:query "emacs"))))))
        (should-not (plist-get r :is-error))
        (should (string-match-p "About emacs" (plist-get r :content))))
      (should (eq 'allow (plist-get (harness-test-await
                                     (harness-call 'tools/authorize "s1"
                                                   '(:id "c2" :name "web_search" :input (:query "emacs"))))
                                    :behavior)))
      (let ((r (harness-test-await (harness-call 'tools/execute "s1"
                                                 '(:id "c3" :name "web_fetch" :input (:url "https://example.org/"))))))
        (should (plist-get r :denied))
        (should (string-match-p "\\`Denied: corporate mode: network tools other than web search are off"
                                (plist-get r :content))))
      (should (null (funcall probe 'requests)))
      (let ((harness-perms-rules '((:tool "web_search" :behavior deny))))
        (should (plist-get (harness-test-await
                            (harness-call 'tools/execute "s1"
                                          '(:id "c4" :name "web_search" :input (:query "emacs"))))
                           :denied))
        (should (eq 'deny (plist-get (harness-test-await
                                      (harness-call 'tools/authorize "s1"
                                                    '(:id "c5" :name "web_search" :input (:query "emacs"))))
                                     :behavior)))))))

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
    ;; The same answers as any other request, allow-once included.
    (should (equal harness-perms-dir-request-options (plist-get payload :options)))
    (should (equal harness-perms-options (plist-get payload :options)))
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
      ;; "Allow" (once) grants the directory until the turn ends: to
      ;; no session, and nothing is saved.
      (let ((s (harness-perms-test--start-request b)))
        (should (string-match-p "The agent asks for access to this directory\\."
                                (plist-get (plist-get (cdr s) :payload) :reason)))
        (harness-call 'permission/answer "s1" (plist-get (cdr s) :id) '(:behavior allow :scope once))
        (let ((d (harness-test-await (car s))))
          (should (eq 'allow (plist-get d :behavior)))
          (should (string-match-p "until this turn ends" (plist-get d :reason)))))
      (should (equal (list (harness-perms-test--real b)) (gethash "s1" harness-perms--turn-dirs)))
      (should-not (gethash "s1" harness-perms--allowed-dirs))
      (should (member (harness-perms-test--real b) (harness-call 'permission/allowed-dirs "s1")))
      (should (equal (list (harness-perms-test--real a)) harness-allowed-directories))
      (should (= 1 (length saved))))))

(ert-deftest harness-perms-dir-request-allow-once-lasts-the-turn ()
  "Allow on an agent's own request grants the directory until the turn ends.
Meanwhile it is a root of the session, listed and revocable; the agent
is told it has to ask again in a later turn; nothing is kept after."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (let* ((outside (harness-perms-test--real (harness-test-temp-dir)))
         (file (expand-file-name "notes.md" outside))
         (events nil))
    (harness-on 'permission/dir-allowed (lambda (sid dir) (push (list 'allowed sid dir) events)))
    (harness-on 'permission/dir-revoked (lambda (sid dir) (push (list 'revoked sid dir) events)))
    (should-not (member outside (harness-call 'permission/allowed-dirs "s1")))
    (let* ((started (harness-perms-test--start-request outside "read the notes"))
           (d (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "allow-once")))
      (should (eq 'allow (plist-get d :behavior)))
      (should (plist-get d :final))
      (should (string-match-p "to this session until this turn ends" (plist-get d :reason)))
      ;; The agent is told how long it has.
      (let ((r (harness-perms--dir-request-result (plist-get (harness-test-await (car started)) :input)
                                                  (list :session-id "s1"))))
        (should-not (plist-get r :is-error))
        (should (string-match-p "is now allowed for the rest of this turn (ask again in a later turn"
                                (plist-get r :content)))))
    ;; Meanwhile it is a root: the jail lets its files through, and the
    ;; directory list shows it, revocable.
    (should (member outside (harness-call 'permission/allowed-dirs "s1")))
    (should (eq 'allow (harness-perms-test--behavior "read_file" 'read file)))
    (let ((e (cl-find outside (harness-call 'permission/dirs "s1")
                      :key (lambda (e) (plist-get e :dir)) :test #'equal)))
      (should (eq 'turn (plist-get e :source)))
      (should (plist-get e :revocable)))
    (should (equal (list (list 'allowed "s1" outside)) events))
    ;; Nothing is kept: no session grant, no rule.
    (should-not (gethash "s1" harness-perms--allowed-dirs))
    (should-not (gethash "s1" harness-perms--session-rules))
    ;; Another session's turn ending changes nothing; this one's ends it.
    (harness-emit 'agent/turn-ended "s2" 'end-turn)
    (should (member outside (harness-call 'permission/allowed-dirs "s1")))
    (harness-emit 'agent/turn-ended "s1" 'end-turn)
    (should-not (member outside (harness-call 'permission/allowed-dirs "s1")))
    (should-not (gethash "s1" harness-perms--turn-dirs))
    (should (equal (list 'revoked "s1" outside) (car events)))
    ;; So asking again asks the user again.
    (let ((started (harness-perms-test--start-request outside "read the notes again")))
      (should-not (harness-promise-settled-p (car started)))
      (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "deny-once")
      (should (eq 'deny (plist-get (harness-test-await (car started)) :behavior))))))

(ert-deftest harness-perms-turn-grant-ends-and-revokes ()
  "A grant until the turn ends also goes when the next turn starts, or when revoked."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (let ((a (harness-perms-test--real (harness-test-temp-dir)))
        (b (harness-perms-test--real (harness-test-temp-dir))))
    (should (equal a (harness-perms--grant-for-turn "s1" a)))
    (harness-perms--grant-for-turn "s1" b)
    (harness-perms--grant-for-turn "s1" a)
    (should (equal (list a b) (gethash "s1" harness-perms--turn-dirs)))
    ;; Revoked from the directory list, like a session grant.
    (harness-call 'permission/revoke-dir "s1" a)
    (should (equal (list b) (gethash "s1" harness-perms--turn-dirs)))
    (should-not (member a (harness-call 'permission/allowed-dirs "s1")))
    ;; A grant made while no turn ran (the turn that asked was cancelled
    ;; before the answer) does not reach the next turn.
    (harness-emit 'agent/turn-started "s1")
    (should-not (gethash "s1" harness-perms--turn-dirs))
    (should-not (member b (harness-call 'permission/allowed-dirs "s1")))
    ;; Unloading the module stops listening.
    (harness-perms--grant-for-turn "s1" b)
    (harness-perms--shutdown)
    (harness-emit 'agent/turn-ended "s1" 'end-turn)
    (should (equal (list b) (gethash "s1" harness-perms--turn-dirs)))
    (clrhash harness-perms--turn-dirs)))

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
  (clrhash harness-perms--judging)
  (clrhash harness-perms--allowed-dirs)
  (clrhash harness-perms--session-rules)
  (clrhash harness-perms--turn-dirs)
  ;; Call ids repeat from test to test: one steered before must not
  ;; keep the agent from being steered again.
  (setq harness-perms--steered nil)
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

;;;; Switching to non-interactive with a prompt waiting

(defun harness-perms-test--start-call (tool kind)
  "Start deciding a call to TOOL of KIND that touches no path.
Return (PROMISE . PENDING) once its prompt waits."
  (let ((n (length harness-perms-test--pending))
        (p (harness-run-filter-async 'permission/decide (list :behavior 'ask)
                                     (harness-perms-test--request tool kind))))
    (harness-test-wait (lambda () (> (length harness-perms-test--pending) n)) 2 "pending")
    (cons p (car harness-perms-test--pending))))

(ert-deftest harness-perms-non-interactive-switch-judges-waiting-prompts ()
  "Switching a waiting session to non-interactive has its prompts decided
as a new call would be, the judge deciding in the user's place, and its
verdict answers the prompt for the call alone.  A directory prompt waits
on: only the user grants a directory."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (let* ((harness-perms-auto-model "judge:small")
         (harness-perms--auto-timeout 2)
         (probe (harness-perms-test--allowing-judge))
         (dir (harness-perms-test--start "read_file" 'read (expand-file-name "x.txt" (harness-test-temp-dir))))
         (tool (harness-perms-test--start-call "bash" 'exec)))
    (should (= 2 (length harness-perms-test--pending)))
    ;; Another change, interactive still: nothing is judged.
    (harness-emit 'session/updated "s1" '(:permission-mode accept-edits))
    (accept-process-output nil 0.1)
    (should (null (funcall probe 'requests)))
    (should-not (harness-promise-settled-p (car tool)))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :non-interactive t))
    (harness-emit 'session/updated "s1" '(:non-interactive t))
    (let ((d (harness-test-await (car tool))))
      (should (eq 'allow (plist-get d :behavior)))
      (should (equal "ordinary work" (plist-get d :reason)))
      (should (plist-get d :final)))
    (should (= 1 (length (funcall probe 'requests))))
    ;; Answered once, for this call: no rule left behind.
    (let ((answered (assoc (plist-get (cdr tool) :id) harness-perms-test--resolved)))
      (should (eq 'allow (plist-get (cdr answered) :behavior)))
      (should (eq 'once (plist-get (cdr answered) :scope))))
    (should (null (gethash "s1" harness-perms--session-rules)))
    ;; The directory prompt waits on, through another switch too.
    (harness-emit 'session/updated "s1" '(:non-interactive t))
    (accept-process-output nil 0.1)
    (should-not (harness-promise-settled-p (car dir)))
    (should (equal (list (plist-get (cdr dir) :id))
                   (mapcar (lambda (p) (plist-get p :id)) harness-perms-test--pending)))
    (should (= 1 (length (funcall probe 'requests))))
    (harness-call 'permission/answer "s1" (plist-get (cdr dir) :id) "deny-once")
    (should (eq 'deny (plist-get (harness-test-await (car dir)) :behavior)))))

(ert-deftest harness-perms-non-interactive-switch-denies-and-steers ()
  "A blocked session switched to non-interactive gets the judge's verdict
on the call it waits on: a denial refuses the call, and the agent is
steered to find another way, as after any denial while the user is
away.  A directory request of the same session keeps waiting for the
user, whose answer still runs its call."
  (harness-test-with-temp-state
    (unwind-protect
        (let* ((sid (harness-perms-test--real-session 'ask))
               (harness-perms-auto-model "judge:small")
               (harness-perms--auto-timeout 2)
               (prompts (harness-perms-test--prompts))
               (outside (harness-test-temp-dir))
               (ran nil))
          (harness-perms-test--judge-provider '((:type text :delta "{\"decision\":\"deny\",\"reason\":\"not that\"}")
                                                (:type done :stop-reason end-turn)))
          (harness-define-tool "t_exec" :label "Run" :kind 'exec
                               :handler (lambda (_in _ctx) (push 'exec ran) "done"))
          (harness-define-tool "t_read" :label "Read" :kind 'read
                               :paths (lambda (in) (list (plist-get in :path)))
                               :handler (lambda (_in _ctx) (push 'read ran) "read"))
          (let ((exec (harness-call 'tools/execute sid (list :id "c1" :name "t_exec" :input '(:command "x"))))
                (read (harness-call 'tools/execute sid (list :id "c2" :name "t_read"
                                                             :input (list :path (expand-file-name "x.txt" outside))))))
            (harness-test-wait (lambda () (= 2 (length (harness-call 'session/pending sid)))) 2 "both prompts")
            (should (eq 'blocked (plist-get (harness-call 'session/get sid) :status)))
            (harness-call 'session/update sid :non-interactive t)
            (let ((r (harness-test-await exec)))
              (should (plist-get r :denied))
              (should (string-match-p "\\`Denied: not that" (plist-get r :content))))
            (should (equal (list (cons sid (format harness-perms-steering-text "t_exec"))) (funcall prompts)))
            ;; The directory prompt is the one left, and its call waits.
            (let ((left (harness-call 'session/pending sid)))
              (should (= 1 (length left)))
              (should (plist-get (plist-get (car left) :payload) :dir))
              (should-not (harness-promise-settled-p read))
              (should-not ran)
              (harness-call 'permission/answer sid (plist-get (car left) :id) "allow-once"))
            (should (equal "read" (plist-get (harness-test-await read) :content)))
            (should (equal '(read) ran))
            (should (null (harness-call 'session/pending sid)))))
      (clrhash harness-sessions))))

;;;; Requests to turn non-interactive mode on

(defun harness-perms-test--away-request (&rest input)
  "Build a request of the set_non_interactive tool with INPUT."
  (list :session harness-perms-test--session :tool harness-perms-away-tool :kind 'meta
        :input input :call-id (harness-short-id)))

(defun harness-perms-test--start-away (&rest input)
  "Start deciding a set_non_interactive call with INPUT; return (PROMISE . PENDING)."
  (let ((n (length harness-perms-test--pending))
        (p (harness-run-filter-async 'permission/decide (list :behavior 'ask)
                                     (apply #'harness-perms-test--away-request input))))
    (harness-test-wait (lambda () (> (length harness-perms-test--pending) n)) 2 "pending")
    (cons p (car harness-perms-test--pending))))

(ert-deftest harness-perms-away-request-always-asks-the-user ()
  "Turning non-interactive mode on asks the user in every permission mode.
Neither a standing rule, nor yolo, nor the auto-mode judge approves it,
and the user's answer holds for the call alone, whatever its scope."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (let ((harness-perms-auto-model "judge:small")
        (probe (harness-perms-test--allowing-judge)))
    (harness-perms-add-rule "s1" (list :tool harness-perms-away-tool :behavior 'allow) 'session)
    (dolist (mode '(ask accept-edits auto yolo))
      (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode mode))
      (let* ((started (harness-perms-test--start-away :enabled t :all t :reason "I am leaving for the day."))
             (payload (plist-get (cdr started) :payload)))
        (should-not (harness-promise-settled-p (car started)))
        (should (equal "Turn non-interactive mode on for every current session and task, of every project"
                       (plist-get payload :title)))
        (should (string-prefix-p "The agent asks: I am leaving for the day.  Nobody is asked anything there"
                                 (plist-get payload :reason)))
        (should (equal harness-perms-away-options (plist-get payload :options)))
        (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "allow-always")
        (let ((d (harness-test-await (car started))))
          (should (eq 'allow (plist-get d :behavior)))
          (should (plist-get d :final))
          (should (equal "the user confirmed it" (plist-get d :reason))))))
    (should (null (funcall probe 'requests)))
    ;; The answer recorded nothing: the rule added above is the only one.
    (should (= 1 (length (gethash "s1" harness-perms--session-rules))))
    ;; Refused, the agent is told not to ask again.
    (let ((started (harness-perms-test--start-away :enabled t :session_id "other")))
      (should (equal "Turn non-interactive mode on for session other"
                     (plist-get (plist-get (cdr started) :payload) :title)))
      (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "deny-once")
      (let ((d (harness-test-await (car started))))
        (should (eq 'deny (plist-get d :behavior)))
        (should (equal "the user refused it" (plist-get d :reason)))
        (should (string-match-p "Do not ask again" (plist-get d :hint)))))))

(ert-deftest harness-perms-away-request-survives-the-switches ()
  "Neither a switch to yolo nor one to non-interactive answers the request:
it waits for the user."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (let ((harness-perms-auto-model "judge:small")
        (probe (harness-perms-test--allowing-judge))
        (started (harness-perms-test--start-away :enabled t)))
    (should (equal "Turn non-interactive mode on for this session"
                   (plist-get (plist-get (cdr started) :payload) :title)))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode 'yolo))
    (harness-emit 'session/updated "s1" '(:permission-mode yolo))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :non-interactive t))
    (harness-emit 'session/updated "s1" '(:non-interactive t))
    (accept-process-output nil 0.2)
    (should-not (harness-promise-settled-p (car started)))
    (should (null (funcall probe 'requests)))
    (should (= 1 (length harness-perms-test--pending)))
    (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "allow-once")
    (should (eq 'allow (plist-get (harness-test-await (car started)) :behavior)))))

(ert-deftest harness-perms-away-request-without-anyone-to-ask ()
  "A non-interactive session cannot ask, so its request to turn the mode
on is denied at once, in every mode, and the hint says to carry on.
Turning it off needs no answer: it only brings the user back in."
  (harness-perms-test--setup :permission-mode 'yolo :non-interactive t)
  (harness-perms-test--install-pending)
  (let ((harness-perms-auto-model "judge:small")
        (probe (harness-perms-test--allowing-judge)))
    (harness-perms-add-rule "s1" (list :tool harness-perms-away-tool :behavior 'allow) 'session)
    (dolist (mode '(yolo auto ask))
      (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode mode))
      (let ((d (harness-perms-test--decide (harness-perms-test--away-request :enabled t :all t))))
        (should (eq 'deny (plist-get d :behavior)))
        (should (plist-get d :final))
        (should (equal (concat "nobody can confirm turning non-interactive mode on for every current session"
                               " and task, of every project: this session is non-interactive and the user is away")
                       (plist-get d :reason)))
        (should (string-match-p "Do not ask again" (plist-get d :hint)))))
    (should (null harness-perms-test--pending))
    (should (null (funcall probe 'requests)))
    ;; Off, in an interactive ask-mode session too, with a rule against it.
    (dolist (away '(t nil))
      (setq harness-perms-test--session (plist-put (plist-put harness-perms-test--session :permission-mode 'ask)
                                                   :non-interactive away))
      (dolist (enabled '(:false nil))
        (let ((d (harness-perms-test--decide (harness-perms-test--away-request :enabled enabled))))
          (should (eq 'allow (plist-get d :behavior)))
          (should (string-match-p "brings the user back in" (plist-get d :reason))))))
    (should (null harness-perms-test--pending)))
  ;; Without sessions to hold a prompt, nobody can answer either.
  (harness-perms-test--setup :permission-mode 'ask)
  (let ((d (harness-perms-test--decide (harness-perms-test--away-request :enabled t))))
    (should (eq 'deny (plist-get d :behavior)))
    (should (string-match-p "no user is available" (plist-get d :reason)))))

(ert-deftest harness-perms-away-request-end-to-end ()
  "The set_non_interactive tool asks before turning the mode on, and runs
once the user confirms; the session then is non-interactive.  From
there, asking again is refused at once, and turning it off runs as
asked."
  (harness-test-with-temp-state
    (unwind-protect
        (progn
          (harness-test-reset-bus)
          (dolist (m '(store project config provider provider-demo session tools agent perms tools-sessions))
            (harness-test-load-module m))
          (clrhash harness-sessions)
          (clrhash harness-perms--waiting)
          (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted"
                                               :permission-mode 'yolo)
                                 :id))
                 (run (lambda (input)
                        (harness-call 'tools/execute sid (list :id (harness-short-id) :name "set_non_interactive"
                                                               :input input))))
                 (prompts (harness-perms-test--prompts))
                 (p (funcall run '(:enabled t :reason "The user is leaving"))))
            (harness-test-wait (lambda () (harness-call 'session/pending sid)) 2 "the confirmation")
            (should-not (harness-promise-settled-p p))
            (should-not (plist-get (harness-call 'session/get sid) :non-interactive))
            (harness-call 'permission/answer sid (plist-get (car (harness-call 'session/pending sid)) :id) "allow-once")
            (let ((r (harness-test-await p)))
              (should-not (plist-get r :is-error))
              (should (equal "Non-interactive mode is now on for this session." (plist-get r :content))))
            (should (plist-get (harness-call 'session/get sid) :non-interactive))
            ;; Non-interactive now: refused at once, nothing waits, and
            ;; the agent is not steered to reach that goal some other
            ;; way, as it is after any other denial.
            (harness-register-method 'agent/running (lambda (&rest _) t))
            (let ((r (harness-test-await (funcall run '(:enabled t :all t)))))
              (should (plist-get r :denied))
              (should (string-match-p "nobody can confirm" (plist-get r :content))))
            (should (null (harness-call 'session/pending sid)))
            (should (null (funcall prompts)))
            (harness-perms--on-decided sid (list :tool "bash" :call-id (harness-short-id)) (list :behavior 'deny))
            (should (equal (list (cons sid (format harness-perms-steering-text "bash"))) (funcall prompts)))
            ;; Off needs nobody.
            (let ((r (harness-test-await (funcall run '(:enabled :false)))))
              (should-not (plist-get r :is-error))
              (should (equal "Non-interactive mode is now off for this session." (plist-get r :content))))
            (should-not (plist-get (harness-call 'session/get sid) :non-interactive))))
      (clrhash harness-sessions))))

;;;; Confirmations

(defun harness-perms-test--confirming-stage ()
  "Have every call of the tool t_confirm confirmed, as a tool's stage would."
  (harness-add-filter 'permission/decide
                      (lambda (decision next request)
                        (if (equal (plist-get request :tool) "t_confirm")
                            (harness-perms-confirm request next
                                                   :title "Confirm: do it" :reason "It does what only you decide."
                                                   :paths '("/somewhere/") :input '(:confirmed yes)
                                                   :hint "Do something else.")
                          (funcall next decision)))
                      6))

(ert-deftest harness-perms-confirm-asks-every-time ()
  "A confirmation offers allow-once and deny-once, survives a switch to
yolo, hands the call the confirmed input and records no rule, whatever
the answer names."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (harness-perms-test--confirming-stage)
  (let ((p (harness-run-filter-async 'permission/decide (list :behavior 'ask)
                                     (harness-perms-test--request "t_confirm" 'meta))))
    (harness-test-wait (lambda () harness-perms-test--pending) 2 "the confirmation")
    (let ((payload (plist-get (car harness-perms-test--pending) :payload)))
      (should (equal '(allow-once deny-once) (plist-get payload :options)))
      (should (equal "Confirm: do it" (plist-get payload :title)))
      (should (equal "It does what only you decide." (plist-get payload :reason)))
      (should (equal '("/somewhere/") (plist-get payload :paths)))
      (should (plist-get payload :confirm)))
    ;; Listed with its own title and options, too.
    (let ((listed (plist-get (car (hash-table-values harness-perms--waiting)) :options)))
      (should (equal '(allow-once deny-once) listed)))
    ;; Yolo does not answer it: only the user does.
    (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode 'yolo))
    (harness-emit 'session/updated "s1" '(:permission-mode yolo))
    (accept-process-output nil 0.1)
    (should-not (harness-promise-settled-p p))
    (harness-call 'permission/answer "s1" (plist-get (car harness-perms-test--pending) :id) "allow-always")
    (let ((d (harness-test-await p)))
      (should (eq 'allow (plist-get d :behavior)))
      (should (plist-get d :final))
      (should (equal '(:confirmed yes) (plist-get d :input)))))
  (should-not harness-perms-rules)
  (should-not (gethash "s1" harness-perms--session-rules))
  ;; A no denies this call, with the stage's hint; the next call asks again.
  (let ((p (harness-run-filter-async 'permission/decide (list :behavior 'ask)
                                     (harness-perms-test--request "t_confirm" 'meta))))
    (harness-test-wait (lambda () harness-perms-test--pending) 2 "the second confirmation")
    (harness-call 'permission/answer "s1" (plist-get (car harness-perms-test--pending) :id) "deny-session")
    (let ((d (harness-test-await p)))
      (should (eq 'deny (plist-get d :behavior)))
      (should (plist-get d :final))
      (should (equal "the user said no" (plist-get d :reason)))
      (should (equal "Do something else." (plist-get d :hint)))))
  (should-not (gethash "s1" harness-perms--session-rules))
  (should (= 2 (length harness-perms-test--resolved))))

(ert-deftest harness-perms-confirm-without-a-user ()
  "A session nobody answers for is denied a confirmation at once."
  (harness-perms-test--setup :permission-mode 'yolo :non-interactive t)
  (harness-perms-test--install-pending)
  (harness-perms-test--confirming-stage)
  (let ((d (harness-perms-test--decide (harness-perms-test--request "t_confirm" 'meta))))
    (should (eq 'deny (plist-get d :behavior)))
    (should (plist-get d :final))
    (should (string-match-p "needs the user's confirmation, and the session is non-interactive"
                            (plist-get d :reason))))
  (should-not harness-perms-test--pending)
  (should (zerop (hash-table-count harness-perms--waiting))))

(ert-deftest harness-perms-allow-dir-until-the-turn-ends ()
  "`permission/allow-dir' with scope `turn' grants a directory to the
session until its turn ends, and nothing is kept."
  (harness-perms-test--setup :permission-mode 'ask)
  (let ((dir (harness-perms-test--real (harness-test-temp-dir)))
        (allowed nil))
    (harness-on 'permission/dir-allowed (lambda (sid d) (push (cons sid d) allowed)))
    (harness-call 'permission/allow-dir "s1" dir 'turn)
    (should (equal (list (cons "s1" dir)) allowed))
    (should (equal (list dir) (gethash "s1" harness-perms--turn-dirs)))
    (should (member dir (harness-call 'permission/allowed-dirs "s1")))
    (should-not (plist-get harness-perms-test--session :allowed-dirs))
    (should-not (gethash "s1" harness-perms--allowed-dirs))
    (harness-emit 'agent/turn-ended "s1" 'end-turn)
    (should-not (member dir (harness-call 'permission/allowed-dirs "s1")))))

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
      (should (string-match-p "now an allowed directory of this session" (plist-get r :content)))
      ;; The sandbox shows a grant to bash, wherever bash runs.
      (should (string-search "bash sees it at the same path" (plist-get r :content))))
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
  "A prompt about a path outside is answered for everything in its directory.
Unless the user edits it.  A prompt about a call inside the allowed
directories offers no pattern at all."
  (let* ((s (harness-perms-test--setup :permission-mode 'ask))
         (cwd (harness-perms-test--real (plist-get s :cwd)))
         (outside (harness-perms-test--real (harness-test-temp-dir)))
         (sub (file-name-as-directory (expand-file-name "sub" outside))))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :cwd cwd))
    (make-directory sub)
    (harness-perms-test--install-pending)
    (dolist (case (list (list "read_file" 'read (expand-file-name "x.txt" outside) (concat outside "**"))
                        ;; A directory stands for itself.
                        (list "list_dir" 'read (directory-file-name sub) (concat sub "**"))
                        ;; Inside the jail the mode asks about the call itself.
                        (list "write_file" 'write (expand-file-name "lisp/a.el" cwd) nil)
                        (list "bash" 'exec cwd nil)))
      (pcase-let ((`(,tool ,kind ,path ,pattern) case))
        (let* ((started (harness-perms-test--start tool kind path))
               (payload (plist-get (cdr started) :payload)))
          (should (equal pattern (plist-get payload :pattern)))
          ;; Only a prompt about a directory has the key at all.
          (should (eq (and pattern t) (and (plist-member payload :pattern) t)))
          (should (eq (and pattern t) (and (plist-get payload :dir) t)))
          (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "deny-once")
          (should (eq 'deny (plist-get (harness-test-await (car started)) :behavior))))))
    ;; A call with no path has no pattern, and its answers hold for the tool.
    (let ((p (harness-run-filter-async 'permission/decide (list :behavior 'ask)
                                       (harness-perms-test--request "elisp" 'exec))))
      (harness-test-wait (lambda () harness-perms-test--pending) 2 "pending")
      (should-not (plist-member (plist-get (car harness-perms-test--pending) :payload) :pattern))
      (harness-call 'permission/answer "s1" (plist-get (car harness-perms-test--pending) :id) "allow-session")
      (harness-test-await p)
      (should (equal '((:tool "elisp" :behavior allow)) (gethash "s1" harness-perms--session-rules))))))

(defun harness-perms-test--tree (root &rest files)
  "Make FILES under ROOT and return ROOT.
Each is a name relative to ROOT; one ending in a slash is a directory."
  (dolist (f files)
    (let ((path (expand-file-name f root)))
      (if (directory-name-p f)
          (make-directory path t)
        (make-directory (file-name-directory path) t)
        (write-region (format ";; %s\n" f) nil path nil 'silent))))
  root)

(defmacro harness-perms-test-with-home (home &rest body)
  "Run BODY with HOME, a fresh directory, as the home directory.
`~' and `abbreviate-file-name' follow it; it is deleted afterwards."
  (declare (indent 1))
  `(let* ((,home (harness-perms-test--real (harness-test-temp-dir)))
          (process-environment (cons (concat "HOME=" (directory-file-name ,home)) process-environment))
          (abbreviated-home-dir nil))
     (unwind-protect (progn ,@body)
       (delete-directory ,home t))))

(ert-deftest harness-perms-one-answer-opens-the-repository ()
  "A session reaching around one tree outside asks the user once.
This replays a session that had to grant the same tree three times:
emacs_find_definition named ~/.emacs.d/modules/doom/compat/compat.el,
reading it asked for that directory alone, and the files, listings and
searches that followed, each a step outside the last grant, asked
again.  Now the file the definition was shown from reads without a
prompt, the first prompt beside it offers the root of the repository,
~/.emacs.d/, and after one allow-session nothing else asks."
  (harness-perms-test-with-home home
    (let* ((emacs-d (harness-perms-test--tree (file-name-as-directory (expand-file-name ".emacs.d" home))
                                              ".git/" "init.el" "modules/doom/compat/compat.el"
                                              "modules/doom/compat/other.el" "modules/lang/x.el"
                                              "sources/doom+/doom+.el"))
           (compat (expand-file-name "modules/doom/compat/" emacs-d))
           (prompts 0))
      (harness-perms-test--setup :permission-mode 'ask)
      (harness-perms-test--install-pending)
      (clrhash harness-perms--revealed)
      (harness-on 'permission/requested (lambda (&rest _) (cl-incf prompts)))
      ;; emacs_find_definition showed a definition in compat.el.
      (harness-call 'permission/reveal-file "s1" (expand-file-name "compat.el" compat))
      (should (eq 'allow (harness-perms-test--behavior "read_file" 'read (expand-file-name "compat.el" compat))))
      (should (= 0 prompts))
      ;; The file beside it asks, for the whole repository.
      (let* ((started (harness-perms-test--start "read_file" 'read (expand-file-name "other.el" compat)))
             (payload (plist-get (cdr started) :payload)))
        (should (equal emacs-d (plist-get payload :dir)))
        (should (equal (concat emacs-d "**") (plist-get payload :pattern)))
        (should (equal "Access ~/.emacs.d/" (plist-get payload :title)))
        ;; The reason still names the file the call wants.
        (should (string-search "~/.emacs.d/modules/doom/compat/other.el" (plist-get payload :reason)))
        (should (eq 'continue (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "allow-session")))
        (should (eq 'allow (plist-get (harness-test-await (car started)) :behavior))))
      (should (= 1 prompts))
      ;; What the session did next asks nothing more.
      (dolist (call `(("list_dir" read ,(expand-file-name "modules" emacs-d))
                      ("glob" read ,(directory-file-name emacs-d))
                      ("grep" read ,(expand-file-name "modules/lang" emacs-d))
                      ("read_file" read ,(expand-file-name "sources/doom+/doom+.el" emacs-d))
                      ("list_dir" read ,(expand-file-name "sources/doom+" emacs-d))))
        (should (eq 'allow (apply #'harness-perms-test--behavior call))))
      (should (= 1 prompts))
      (should (null harness-perms-test--pending))
      ;; One grant, the root, kept as the directory.
      (should (equal (list emacs-d) (harness-perms--granted harness-perms-test--session))))))

(ert-deftest harness-perms-prompt-root-stays-within-bounds ()
  "A prompt offers the repository's root only when that opens no more than it.
Without a repository the prompt offers the directory itself, as it
does when the root is the home directory or holds it, or holds the
session's working directory or worktree (the main checkout of a
worktree, say).  A remote directory is not looked into."
  (harness-perms-test-with-home home
    (let* ((plain (harness-perms-test--tree (harness-perms-test--real (harness-test-temp-dir)) "a/b.txt"))
           (repo (harness-perms-test--tree (file-name-as-directory (expand-file-name "repo" home))
                                           ".git/" "lisp/a.el" "docs/x/y.md"))
           (worktree (harness-perms-test--tree (file-name-as-directory (expand-file-name ".worktrees/task" repo))
                                               ".git" "lisp/a.el"))
           ;; A session working elsewhere; the jail's below works in the worktree.
           (s (list :id "s1" :cwd (harness-perms-test--real (harness-test-temp-dir))))
           (in (lambda (dir name) (file-name-as-directory (expand-file-name name dir)))))
      (harness-perms-test--setup :permission-mode 'ask)
      (unwind-protect
          (progn
            (should (equal (funcall in plain "a") (harness-perms--prompt-dir s (funcall in plain "a"))))
            ;; The root, from any depth below it.
            (should (equal repo (harness-perms--prompt-dir s (funcall in repo "docs/x"))))
            (should (equal repo (harness-perms--prompt-dir s repo)))
            ;; A worktree is a repository of its own.
            (should (equal worktree (harness-perms--prompt-dir s (funcall in worktree "lisp"))))
            ;; The main checkout of the session's own worktree.
            (dolist (session (list (list :id "s1" :cwd worktree)
                                   (list :id "s1" :cwd (funcall in worktree "lisp") :worktree worktree)))
              (should (equal (funcall in repo "lisp") (harness-perms--prompt-dir session (funcall in repo "lisp")))))
            ;; Through the jail: the prompt for a file of the main checkout.
            (setq harness-perms-test--session (plist-put harness-perms-test--session :cwd worktree))
            (harness-perms-test--install-pending)
            (let ((started (harness-perms-test--start "read_file" 'read (expand-file-name "lisp/a.el" repo))))
              (should (equal (concat (funcall in repo "lisp") "**")
                             (plist-get (plist-get (cdr started) :payload) :pattern)))
              (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "deny-once")
              (harness-test-await (car started)))
            ;; The home directory kept in git: what lies in it directly
            ;; offers its own directory, a repository below it its root.
            (make-directory (expand-file-name ".git" home))
            (harness-perms-test--tree home "notes/todo.org")
            (should (equal (funcall in home "notes") (harness-perms--prompt-dir s (funcall in home "notes"))))
            (should (equal repo (harness-perms--prompt-dir s (funcall in repo "docs"))))
            ;; A root that holds the home directory.
            (let* ((outer (harness-perms-test--tree (harness-perms-test--real (harness-test-temp-dir))
                                                    ".git/" "home/" "other/x.txt"))
                   (process-environment (cons (concat "HOME=" (expand-file-name "home" outer)) process-environment)))
              (unwind-protect
                  (should (equal (funcall in outer "other") (harness-perms--prompt-dir s (funcall in outer "other"))))
                (delete-directory outer t)))
            (should (equal "/ssh:u@box:/srv/x/" (harness-perms--prompt-dir s "/ssh:u@box:/srv/x/"))))
        (delete-directory plain t)))))

(ert-deftest harness-perms-revealed-file-reads-without-a-prompt ()
  "A file the user's Emacs showed a definition in may be read, and only read.
emacs_find_definition reports it with `permission/reveal-file'; a call
that only reads may then read that one file, in every mode, while its
directory, the files beside it and writing it stay jailed, a rule still
denies it, and another session gets nothing."
  (let* ((outside (harness-perms-test--real (harness-test-temp-dir)))
         (elsewhere (harness-perms-test--real (harness-test-temp-dir)))
         (file (expand-file-name "compat.el" outside))
         (beside (expand-file-name "other.el" outside))
         (link (expand-file-name "link.el" elsewhere)))
    (harness-perms-test--tree outside "compat.el" "other.el")
    (make-symbolic-link file link)
    (unwind-protect
        (progn
          ;; Nobody to ask here: what the jail stops is denied.
          (harness-perms-test--setup :permission-mode 'ask)
          (clrhash harness-perms--revealed)
          (should (eq 'deny (harness-perms-test--behavior "read_file" 'read file)))
          (should (equal file (harness-call 'permission/reveal-file "s1" file)))
          (dolist (mode '(ask auto accept-edits yolo))
            (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode mode))
            (let ((d (harness-perms-test--decide (harness-perms-test--request "read_file" 'read file))))
              (should (eq 'allow (plist-get d :behavior)))
              (should (string-search "showed a definition" (plist-get d :reason)))))
          (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode 'ask))
          (should (eq 'allow (harness-perms-test--behavior "grep" 'read file)))
          ;; A link to it leads to the same file.
          (should (eq 'allow (harness-perms-test--behavior "read_file" 'read link)))
          ;; Only reading, and only that file.
          (should (eq 'deny (harness-perms-test--behavior "write_file" 'write file)))
          (should (eq 'deny (harness-perms-test--behavior "edit_file" 'write file)))
          (should (eq 'deny (harness-perms-test--behavior "read_file" 'read beside)))
          (should (eq 'deny (harness-perms-test--behavior "list_dir" 'read outside)))
          (should (eq 'deny (harness-perms-test--behavior "grep" 'read outside)))
          ;; Another session.
          (should (eq 'deny (plist-get (harness-perms-test--decide
                                        (list :session (list :id "s2" :cwd (plist-get harness-perms-test--session :cwd))
                                              :tool "read_file" :kind 'read :input (list :path file) :paths (list file)))
                                       :behavior)))
          ;; A standing rule still decides first.
          (harness-perms-add-rule "s1" (list :path file :behavior 'deny) 'session)
          (should (eq 'deny (harness-perms-test--behavior "read_file" 'read file)))
          ;; Only an existing local file is recorded.
          (should-not (harness-call 'permission/reveal-file "s1" outside))
          (should-not (harness-call 'permission/reveal-file "s1" (expand-file-name "missing.el" outside)))
          (should-not (harness-call 'permission/reveal-file "s1" "compat.el"))
          (should-not (harness-call 'permission/reveal-file "s1" "/ssh:u@box:/srv/a.el"))
          (should (equal (list file) (gethash "s1" harness-perms--revealed)))
          ;; A deleted session's files are forgotten.
          (harness-emit 'session/deleted "s1" nil)
          (should-not (gethash "s1" harness-perms--revealed)))
      (delete-directory outside t)
      (delete-directory elsewhere t))))

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

(ert-deftest harness-perms-tool-prompt-remembers-for-the-tool ()
  "Answers for the session or always to a prompt about a call hold for its tool.
The prompt offered no pattern, so none narrows the rule, not even one
in the answer; the jail still asks about a path outside first."
  (let* ((saved nil)
         (s (harness-perms-test--setup :permission-mode 'ask))
         (cwd (harness-perms-test--real (plist-get s :cwd)))
         (lisp (file-name-as-directory (expand-file-name "lisp" cwd)))
         (outside (harness-perms-test--real (harness-test-temp-dir))))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :cwd cwd))
    (harness-perms-test--install-pending)
    (cl-letf (((symbol-function 'harness-save-user-option)
               (lambda (sym value) (set sym value) (push (cons sym value) saved))))
      (let ((started (harness-perms-test--start "write_file" 'write (expand-file-name "a.el" lisp))))
        (should-not (plist-get (plist-get (cdr started) :payload) :dir))
        (should-not (plist-member (plist-get (cdr started) :payload) :pattern))
        (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "allow-session")
        (should (eq 'allow (plist-get (harness-test-await (car started)) :behavior))))
      (should (equal '((:tool "write_file" :behavior allow)) (gethash "s1" harness-perms--session-rules)))
      ;; Any file in the allowed directories needs no answer now, not only lisp/'s.
      (should (eq 'allow (harness-perms-test--behavior "write_file" 'write (expand-file-name "README" cwd))))
      (should (null harness-perms-test--pending))
      ;; Outside them, the jail asks about the directory first.
      (let ((out (harness-perms-test--start "write_file" 'write (expand-file-name "x.el" outside))))
        (should (equal outside (plist-get (plist-get (cdr out) :payload) :dir)))
        (harness-call 'permission/answer "s1" (plist-get (cdr out) :id) "deny-once")
        (should (eq 'deny (plist-get (harness-test-await (car out)) :behavior))))
      ;; Denied for good: the tool, a pattern in the answer notwithstanding.
      (let ((other (harness-perms-test--start "bash" 'exec cwd)))
        (should-not (plist-member (plist-get (cdr other) :payload) :pattern))
        (harness-call 'permission/answer "s1" (plist-get (cdr other) :id) (list :option "deny-always" :pattern "docs/*.md"))
        (should (eq 'deny (plist-get (harness-test-await (car other)) :behavior))))
      (should (equal '((:tool "bash" :behavior deny)) harness-perms-rules))
      (should (eq 'harness-perms-rules (caar saved)))
      (let ((d (harness-perms-test--decide (harness-perms-test--request "bash" 'exec lisp))))
        (should (eq 'deny (plist-get d :behavior)))
        (should (equal "denied by a standing rule for bash" (plist-get d :reason))))
      (should (null harness-perms-test--pending)))))

(ert-deftest harness-perms-only-a-path-outside-brings-a-pattern ()
  "Only a prompt about a path outside the allowed directories offers a pattern.
A write there first asks for the directory, with its pattern; once that
is allowed, the mode asks about the write itself, without one.  The
auto judge objecting to a call offers none either."
  (let* ((s (harness-perms-test--setup :permission-mode 'ask))
         (cwd (harness-perms-test--real (plist-get s :cwd)))
         (outside (harness-perms-test--real (harness-test-temp-dir)))
         (payload (lambda () (plist-get (car harness-perms-test--pending) :payload))))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :cwd cwd))
    (harness-perms-test--install-pending)
    (harness-define-tool "t_write" :label "Write" :kind 'write :description "Writes a file." :handler #'ignore)
    (let ((started (harness-perms-test--start "t_write" 'write (expand-file-name "x.el" outside))))
      (should (equal outside (plist-get (funcall payload) :dir)))
      (should (equal (concat outside "**") (plist-get (funcall payload) :pattern)))
      (should (eq 'continue (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "allow-once")))
      (harness-test-wait (lambda () harness-perms-test--pending) 2 "the mode's prompt")
      (should-not (plist-get (funcall payload) :dir))
      (should-not (plist-member (funcall payload) :pattern))
      (should (equal (list (expand-file-name "x.el" outside)) (plist-get (funcall payload) :paths)))
      (should (equal harness-perms-options (plist-get (funcall payload) :options)))
      (harness-call 'permission/answer "s1" (plist-get (car harness-perms-test--pending) :id) "allow-once")
      (should (eq 'allow (plist-get (harness-test-await (car started)) :behavior))))
    (should (null harness-perms-test--pending))
    ;; The judge objects to a write in the working directory.
    (setq harness-perms-test--session (plist-put harness-perms-test--session :permission-mode 'auto))
    (harness-perms-test--judge-provider
     '((:type text :delta "{\"decision\":\"deny\",\"reason\":\"it rewrites the build\"}")
       (:type done :stop-reason end-turn)))
    (let* ((harness-perms-auto-model "judge:x")
           (started (harness-perms-test--start "t_write" 'write (expand-file-name "Makefile" cwd))))
      (should (string-match-p "judge would deny this call: it rewrites the build" (plist-get (funcall payload) :reason)))
      (should-not (plist-get (funcall payload) :dir))
      (should-not (plist-member (funcall payload) :pattern))
      (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "deny-once")
      (should (eq 'deny (plist-get (harness-test-await (car started)) :behavior))))))

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
  (should (= 8 (length (gethash 'permission/decide harness--filters))))
  (should (equal 6 (car (rassq #'harness-perms--away-request
                               (gethash 'permission/decide harness--filters)))))
  (should (memq 'permission/requested (mapcar #'car (harness-events))))
  ;; A hot reload loads the file and runs `:init' of the ready module
  ;; again, which installs the stage that decides directory requests.
  (harness-remove-filter 'permission/decide #'harness-perms--dir-request)
  (harness-test-load-module 'perms)
  (should (harness-module-ready-p 'perms))
  (should (rassq #'harness-perms--dir-request (gethash 'permission/decide harness--filters)))
  (should (= 8 (length (gethash 'permission/decide harness--filters)))))

;;;; Inspecting the harness itself

(defun harness-perms-test--call-with-harness (fn)
  "Call FN with (REPO BUILD STATE): a harness installed as straight.el does.
BUILD, which `harness-directory' names, holds a compiled file of its
own and links into the checkout REPO for the sources.  STATE, which
`harness-state-directory' names, holds a session, a task board and the
credentials: the ACP token and the settings forwarded to the harness
process."
  (let* ((repo (harness-test-temp-dir))
         (build (harness-test-temp-dir))
         (harness-directory build)
         ;; The modules a test loads are this tree's all the same, not
         ;; a project's plugins (see `harness-module-plugin-p').
         (harness-module-directories
          (append harness-module-directories
                  (mapcar (lambda (dir) (expand-file-name dir harness-test-root))
                          '("lisp/modules" "lisp/ui")))))
    (harness-test-with-temp-state
      (let ((state harness-state-directory))
        (dolist (dir (list repo build))
          (make-directory (expand-file-name "lisp/modules" dir) t))
        (dolist (file '("harness.el" "lisp/modules/harness-perms.el"))
          (with-temp-file (expand-file-name file repo) (insert ";; " file "\n"))
          (make-symbolic-link (expand-file-name file repo) (expand-file-name file build)))
        (with-temp-file (expand-file-name "harness.elc" build) (insert ";ELC\n"))
        (make-directory (expand-file-name "sessions" state) t)
        (with-temp-file (expand-file-name "sessions/s1.json" state) (insert "{\"id\":\"s1\"}\n"))
        (with-temp-file (expand-file-name "tasks.json" state) (insert "[]\n"))
        (with-temp-file (expand-file-name "acp-token" state) (insert "s3cret-token\n"))
        (with-temp-file (expand-file-name "server-config.el" state)
          (insert "(customize-set-variable 'harness-brave-api-key '\"s3cret-key\")\n"))
        (funcall fn repo build state)))))

(defun harness-perms-test--denying-judge ()
  "Register provider `judge' that denies every call; return its probe."
  (harness-perms-test--judge-provider '((:type text :delta "{\"decision\":\"deny\",\"reason\":\"not the project's\"}")
                                        (:type done :stop-reason end-turn))))

(defun harness-perms-test--each-mode (fn)
  "Call FN in every permission mode, with the user there and away.
The fake session is switched before each call; FN gets the mode and
whether the session is non-interactive."
  (dolist (mode '(ask accept-edits auto yolo))
    (dolist (away '(nil t))
      (setq harness-perms-test--session
            (plist-put (plist-put harness-perms-test--session :permission-mode mode) :non-interactive away))
      (funcall fn mode away))))

(ert-deftest harness-perms-inspection-tools-need-no-approval ()
  "The tools that inspect the harness or the user's Emacs are allowed in
every mode, with the user there or away, and no judge is asked: a
judge denying them cannot stop the agent looking at its own harness."
  (harness-perms-test--setup)
  (harness-perms-test--install-pending)
  (dolist (tool '("emacs_buffers" "emacs_buffer" "emacs_describe" "emacs_messages" "emacs_windows"
                  "session_list" "session_read" "session_search" "session_history" "task_list"))
    (should (member tool harness-perms--inspection-tools)))
  (let ((probe (harness-perms-test--denying-judge))
        (harness-perms-auto-model "judge:x"))
    (harness-perms-test--each-mode
     (lambda (mode away)
       (dolist (tool harness-perms--inspection-tools)
         (ert-info ((format "%s in %s mode%s" tool mode (if away ", user away" "")))
           (let ((d (harness-perms-test--decide (harness-perms-test--request tool 'read))))
             (should (eq 'allow (plist-get d :behavior)))
             (should (string-match-p "only inspects the harness" (plist-get d :reason))))))))
    (should (null (funcall probe 'requests)))
    (should (null harness-perms-test--pending)))
  ;; Shown with the other tools that never need approval.
  (let ((auto-allow (plist-get (harness-call 'permission/rules "s1") :auto-allow)))
    (dolist (tool (append harness-perms--auto-allow-tools harness-perms--inspection-tools))
      (should (member tool auto-allow)))))

(ert-deftest harness-perms-inspection-tools-only-read ()
  "What needs no approval for inspecting the harness reads and nothing
else: each such tool is of kind read and takes no path for the jail."
  (harness-perms-test--setup)
  (let ((harness-tools (make-hash-table :test 'equal)))
    (dolist (library '("harness-tools-emacs" "harness-tools-session-info" "harness-tools-sessions" "harness-tools-notify"
                       "harness-tools-events"))
      (load library nil t))
    (dolist (name harness-perms--inspection-tools)
      (ert-info (name)
        (let ((tool (harness-tool-get name)))
          (should tool)
          (should (eq 'read (harness-tool-kind tool)))
          (should-not (harness-tool-paths-fn tool)))))
    ;; The tools into the user's Emacs that change or open something are
    ;; not on the list.
    (dolist (name '("emacs_insert" "emacs_save_buffer" "emacs_open" "session_send" "session_control"
                    "task_submit" "task_control"))
      (should (harness-tool-get name))
      (should-not (member name harness-perms--inspection-tools)))))

(ert-deftest harness-perms-reading-the-harness-needs-no-approval ()
  "Every session may read the harness's code and state, in every mode,
with the user there or away: no prompt, no judge, no denial.  An
unattended task used to be refused a read of the harness's own
sessions or sources as outside the allowed directories."
  (harness-perms-test--call-with-harness
   (lambda (repo build state)
     (harness-perms-test--setup)
     (harness-perms-test--install-pending)
     (let ((probe (harness-perms-test--denying-judge))
           (harness-perms-auto-model "judge:x")
           (calls `(;; The build directory: a link into the checkout, and a
                    ;; file of its own.
                    ("read_file" ,(expand-file-name "harness.el" build))
                    ("read_file" ,(expand-file-name "harness.elc" build))
                    ("list_dir" ,build)
                    ;; The checkout the links lead to.
                    ("read_file" ,(expand-file-name "lisp/modules/harness-perms.el" repo))
                    ("grep" ,repo)
                    ;; The state directory.
                    ("read_file" ,(expand-file-name "sessions/s1.json" state))
                    ("grep" ,(expand-file-name "sessions" state))
                    ("list_dir" ,state)
                    ("glob" ,state)
                    ("file_info" ,(expand-file-name "tasks.json" state))
                    ("emacs_open" ,(expand-file-name "tasks.json" state)))))
       (harness-perms-test--each-mode
        (lambda (mode away)
          (pcase-dolist (`(,tool ,path) calls)
            (ert-info ((format "%s %s in %s mode%s" tool path mode (if away ", user away" "")))
              (let ((d (harness-perms-test--decide (harness-perms-test--request tool 'read path))))
                (should (eq 'allow (plist-get d :behavior)))
                (should (equal "reading the harness itself never needs approval" (plist-get d :reason))))))))
       (should (null (funcall probe 'requests)))
       (should (null harness-perms-test--pending))
       ;; A read of the project and the harness together is fine too.
       (should (eq 'allow (plist-get (harness-perms-test--decide
                                      (list :session harness-perms-test--session :tool "t_diff" :kind 'read
                                            :paths (list (expand-file-name "a.el" (plist-get harness-perms-test--session :cwd))
                                                         (expand-file-name "harness.el" build))))
                                     :behavior)))
       ;; The harness is shown for what it is: its code and its state.
       (should (equal (list (list :dir build :source 'harness)
                            (list :dir (harness-perms-test--real repo) :source 'harness)
                            (list :dir state :source 'state))
                      (harness-perms-inspection-dirs)))
       (should (equal (list build (harness-perms-test--real repo) state)
                      (plist-get (harness-call 'permission/rules "s1") :inspect)))
       ;; They are no roots of the session.
       (should-not (cl-intersection (list build repo state) (harness-perms-roots harness-perms-test--session)
                                    :test #'equal))))))

(ert-deftest harness-perms-harness-checkout-without-links ()
  "A harness run from a plain checkout is one directory of code."
  (let ((harness-directory (harness-test-temp-dir)))
    (with-temp-file (expand-file-name "harness.el" harness-directory) (insert ";; harness\n"))
    (should (equal (list harness-directory) (harness-perms--harness-code-dirs)))))

(ert-deftest harness-perms-the-harness-stays-read-only ()
  "Reading the harness opens nothing else: a write there, a command run
there or a sub-agent started there is jailed as before, and the agent
is told it may still read it."
  (harness-perms-test--call-with-harness
   (lambda (repo build state)
     (harness-perms-test--setup :permission-mode 'yolo :non-interactive t)
     (let ((probe (harness-perms-test--allowing-judge))
           (harness-perms-auto-model "judge:x"))
       (pcase-dolist (`(,tool ,kind ,path)
                      `(("write_file" write ,(expand-file-name "harness.el" build))
                        ("edit_file" write ,(expand-file-name "lisp/modules/harness-perms.el" repo))
                        ("write_file" write ,(expand-file-name "tasks.json" state))
                        ("bash" exec ,state)
                        ("spawn_agent" meta ,state)
                        ;; A call of no known kind is no read either.
                        ("t_mystery" nil ,(expand-file-name "tasks.json" state))))
         (ert-info ((format "%s %s" tool path))
           (let ((d (harness-perms-test--decide (harness-perms-test--request tool kind path))))
             (should (eq 'deny (plist-get d :behavior)))
             (should (plist-get d :final))
             (should (string-match-p "outside the allowed directories" (plist-get d :reason)))
             (should (string-match-p "part of the harness itself" (plist-get d :hint))))))
       (should (null (funcall probe 'requests))))
     ;; Nothing is granted on the way: asking for the state directory
     ;; still waits for the user, who is away, and the agent hears it
     ;; may read it anyway.
     (let ((d (harness-perms-test--decide (harness-perms-test--dir-request state "read the sessions"))))
       (should (eq 'deny (plist-get d :behavior)))
       (should (string-match-p "part of the harness itself" (plist-get d :hint))))
     ;; With the user there, a write asks for the directory, as anywhere
     ;; outside the roots.
     (setq harness-perms-test--session (plist-put harness-perms-test--session :non-interactive nil))
     (harness-perms-test--install-pending)
     (let ((started (harness-perms-test--start "write_file" 'write (expand-file-name "tasks.json" state))))
       (should (equal (harness-perms-test--real state) (plist-get (plist-get (cdr started) :payload) :dir)))
       (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "deny-once")
       (should (eq 'deny (plist-get (harness-test-await (car started)) :behavior)))))))

(ert-deftest harness-perms-the-harness-credentials-stay-jailed ()
  "Inspecting the harness never reads its credentials, since what a tool
reads goes to the model's provider: the ACP token and the forwarded
settings with their API keys are jailed like anything outside the
allowed directories, and so is a search below a directory holding
them.  Their names are no secret: that directory may be listed."
  (harness-perms-test--call-with-harness
   (lambda (_repo _build state)
     (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
     (let* ((probe (harness-perms-test--allowing-judge))
            (harness-perms-auto-model "judge:x")
            (token (expand-file-name "acp-token" state))
            (config (expand-file-name "server-config.el" state))
            (clips (expand-file-name "clips/" state))
            (outside (harness-test-temp-dir)))
       (make-directory clips)
       (make-symbolic-link token (expand-file-name "token" clips))
       (make-symbolic-link (directory-file-name outside) (expand-file-name "elsewhere" clips))
       (pcase-dolist (`(,tool ,path ,credentials)
                      `(("read_file" ,token t) ("read_file" ,config t) ("file_info" ,token t)
                        ("emacs_open" ,config t) ("list_dir" ,token t)
                        ;; A search reads every file below its path.
                        ("grep" ,state t) ("grep" ,(directory-file-name state) t)
                        ;; Links lead where they point, out of the harness too.
                        ("read_file" ,(expand-file-name "token" clips) t)
                        ("read_file" ,(expand-file-name "elsewhere/x.txt" clips) nil)))
         (ert-info ((format "%s %s" tool path))
           (let ((d (harness-perms-test--decide (harness-perms-test--request tool 'read path))))
             (should (eq 'deny (plist-get d :behavior)))
             (should (string-match-p "outside the allowed directories" (plist-get d :reason)))
             ;; The agent learns why, and what it may read instead.
             (should (eq credentials (and (string-search "No tool may read the harness's credentials"
                                                         (plist-get d :hint))
                                          t)))
             (should-not (string-search "part of the harness itself" (plist-get d :hint))))))
       (should (eq 'allow (harness-perms-test--behavior "list_dir" 'read state)))
       (should (eq 'allow (harness-perms-test--behavior "glob" 'read state)))
       (should (eq 'allow (harness-perms-test--behavior "file_info" 'read state)))
       (should (eq 'allow (harness-perms-test--behavior "grep" 'read clips)))
       (should (null (funcall probe 'requests)))))))

(ert-deftest harness-perms-rules-beat-the-inspection-allowance ()
  "A standing rule still decides first: a user who denied a tool or a
part of the harness keeps it denied."
  (harness-perms-test--call-with-harness
   (lambda (_repo _build state)
     (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
     (let ((harness-perms-rules `((:tool "session_read" :behavior deny)
                                  (:path ,(concat state "sessions/**") :behavior deny))))
       (let ((d (harness-perms-test--decide (harness-perms-test--request "session_read" 'read))))
         (should (eq 'deny (plist-get d :behavior)))
         (should (string-match-p "standing rule" (plist-get d :reason))))
       (should (eq 'allow (harness-perms-test--behavior "session_list" 'read)))
       (let ((d (harness-perms-test--decide
                 (harness-perms-test--request "read_file" 'read (expand-file-name "sessions/s1.json" state)))))
         (should (eq 'deny (plist-get d :behavior)))
         (should (string-match-p "standing rule" (plist-get d :reason))))
       (should (eq 'allow (harness-perms-test--behavior "read_file" 'read (expand-file-name "tasks.json" state))))))))

(ert-deftest harness-perms-judge-is-told-inspecting-the-harness-is-ordinary ()
  "The judge sees inspection of the harness done by other means, such
as Emacs Lisp reading the state directory.  It is told that is ordinary
work wherever the harness lives, where it lives, and that its
credentials are the one exception."
  (harness-perms-test--call-with-harness
   (lambda (repo build state)
     (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
     (dolist (phrase '("inspecting the harness itself wherever it lives" "inside the allowed roots or not"
                       "Emacs Lisp included" "acp-token and server-config.el"))
       (should (string-search phrase harness-perms--judge-system)))
     (let* ((requests (harness-perms-test--scripted-judge
                       '(((:type text :delta "{\"decision\":\"allow\",\"reason\":\"inspection\"}")
                          (:type done :stop-reason end-turn)))))
            (harness-perms-auto-model "judge:x")
            (d (harness-perms-test--decide
                (list :session harness-perms-test--session :tool "elisp" :kind 'exec
                      :input (list :code (format "(with-temp-buffer (insert-file-contents %S) (buffer-string))"
                                                 (expand-file-name "sessions/s1.json" state)))
                      :call-id (harness-short-id))))
            (text (plist-get (car (plist-get (car (plist-get (car (funcall requests)) :messages)) :content)) :text)))
       (should (eq 'allow (plist-get d :behavior)))
       (should (string-search "\nThe harness itself (inspecting it is ordinary work" text))
       (should (string-search (format "- %s (its code)" build) text))
       (should (string-search (format "- %s (its code)" (harness-perms-test--real repo)) text))
       (should (string-search (format "- %s (its state: " state) text))
       (should (string-search (expand-file-name "acp-token" state) text))
       ;; The question still ends the message.
       (should (string-match-p "\n\nIs this one call safe\\?" text))))))

(ert-deftest harness-perms-unattended-session-reads-the-harness-end-to-end ()
  "An unattended auto-mode session reads the harness with the real file
tools, whatever a judge would say, and still cannot read its
credentials."
  (harness-perms-test--call-with-harness
   (lambda (_repo build state)
     (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
     (harness-test-load-module 'tools-fs)
     (let* ((probe (harness-perms-test--denying-judge))
            (harness-perms-auto-model "judge:x")
            (run (lambda (name input)
                   (harness-test-await (harness-call 'tools/execute "s1"
                                                     (list :id (harness-short-id) :name name :input input))))))
       (let ((r (funcall run "read_file" (list :path (expand-file-name "sessions/s1.json" state)))))
         (should-not (plist-get r :is-error))
         (should (string-search "{\"id\":\"s1\"}" (plist-get r :content))))
       (let ((r (funcall run "read_file" (list :path (expand-file-name "lisp/modules/harness-perms.el" build)))))
         (should-not (plist-get r :is-error))
         (should (string-search ";; lisp/modules/harness-perms.el" (plist-get r :content))))
       (let ((r (funcall run "list_dir" (list :path state))))
         (should-not (plist-get r :is-error))
         (should (string-search "acp-token" (plist-get r :content))))
       (let ((r (funcall run "grep" (list :pattern "s3cret" :path (expand-file-name "sessions" state)))))
         (should-not (plist-get r :is-error))
         (should (string-search "No matches" (plist-get r :content))))
       (dolist (input (list (list :path (expand-file-name "acp-token" state))
                            (list :path (expand-file-name "server-config.el" state))))
         (let ((r (funcall run "read_file" input)))
           (should (plist-get r :is-error))
           (should (plist-get r :denied))
           (should-not (string-search "s3cret" (plist-get r :content)))))
       (let ((r (funcall run "grep" (list :pattern "s3cret" :path state))))
         (should (plist-get r :denied))
         (should-not (string-search "s3cret-" (plist-get r :content))))
       (should (null (funcall probe 'requests)))))))

;;;; Reading skills

(defvar harness-skills-directories)
(defvar harness-skills-plugins-directory)

(defun harness-perms-test--write (file text)
  "Write TEXT to FILE, making its directory."
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert text)))

(defun harness-perms-test--call-with-skills (fn)
  "Call FN with (SKILLS LINKED OUTSIDE), skills set up as a user has them.
SKILLS is the user's skills directory, which `harness-skills-directories'
names besides the project's: its skill commit has a file of its own and
leak.txt, a link to OUTSIDE's secret.txt, and its skill linked is a
link to LINKED, as from a dotfiles repository.  The session's project
links its .claude/skills to OUTSIDE.  None is in the session's roots."
  (harness-test-load-module 'skills)
  (let* ((skills (harness-test-temp-dir))
         (linked (expand-file-name "linked/" (harness-test-temp-dir)))
         (outside (harness-test-temp-dir))
         (cwd (plist-get harness-perms-test--session :cwd))
         (harness-skills-plugins-directory (harness-test-temp-dir))
         (harness-skills-directories (list skills #'harness-skills-project-directories)))
    (harness-perms-test--write (expand-file-name "commit/SKILL.md" skills) "---\nname: commit\n---\nCommit.\n")
    (harness-perms-test--write (expand-file-name "commit/reference.md" skills) "Reference.\n")
    (harness-perms-test--write (expand-file-name "SKILL.md" linked) "Linked.\n")
    (harness-perms-test--write (expand-file-name "secret.txt" outside) "s3cret\n")
    (harness-perms-test--write (expand-file-name "stolen/SKILL.md" outside) "Stolen.\n")
    (make-symbolic-link (expand-file-name "secret.txt" outside) (expand-file-name "commit/leak.txt" skills))
    (make-symbolic-link (directory-file-name linked) (expand-file-name "linked" skills))
    (make-directory (expand-file-name ".claude" cwd) t)
    (make-symbolic-link (directory-file-name outside) (expand-file-name ".claude/skills" cwd))
    (harness-call 'skills/refresh)
    (funcall fn skills linked outside)))

(ert-deftest harness-perms-reading-skills-needs-no-approval ()
  "Every session may read the skills directories, in every mode, with
the user there or away: no prompt, no judge, no denial.  An unattended
task used to stop on a prompt for ~/.claude/skills, holding its slot."
  (harness-perms-test--setup)
  (harness-perms-test--install-pending)
  (harness-perms-test--call-with-skills
   (lambda (skills linked _outside)
     (let ((probe (harness-perms-test--denying-judge))
           (harness-perms-auto-model "judge:x")
           (calls `(("read_file" ,(expand-file-name "commit/SKILL.md" skills))
                    ("read_file" ,(expand-file-name "commit/reference.md" skills))
                    ("list_dir" ,skills)
                    ("glob" ,skills)
                    ("grep" ,(expand-file-name "commit" skills))
                    ("file_info" ,(expand-file-name "commit/SKILL.md" skills))
                    ;; A skill linked in from elsewhere, by either name.
                    ("read_file" ,(expand-file-name "linked/SKILL.md" skills))
                    ("list_dir" ,linked))))
       (harness-perms-test--each-mode
        (lambda (mode away)
          (pcase-dolist (`(,tool ,path) calls)
            (ert-info ((format "%s %s in %s mode%s" tool path mode (if away ", user away" "")))
              (let ((d (harness-perms-test--decide (harness-perms-test--request tool 'read path))))
                (should (eq 'allow (plist-get d :behavior)))
                (should (equal "reading skills never needs approval" (plist-get d :reason))))))))
       (should (null (funcall probe 'requests)))
       (should (null harness-perms-test--pending))
       ;; A read of the project and a skill together is fine too.
       (should (eq 'allow (plist-get (harness-perms-test--decide
                                      (list :session harness-perms-test--session :tool "t_diff" :kind 'read
                                            :paths (list (expand-file-name "a.el" (plist-get harness-perms-test--session :cwd))
                                                         (expand-file-name "commit/SKILL.md" skills))))
                                     :behavior)))
       ;; The skills directories are shown with the rules, and are no
       ;; roots of the session.
       (should (equal (list skills (expand-file-name "linked/" skills))
                      (plist-get (harness-call 'permission/rules "s1") :skills)))
       (should-not (cl-intersection (list skills linked) (harness-perms-roots harness-perms-test--session)
                                    :test #'equal))))))

(ert-deftest harness-perms-skills-stay-read-only ()
  "Reading skills opens nothing else: writing there, running a command
there or starting a sub-agent there is jailed as before, and the agent
learns that it may read them."
  (harness-perms-test--setup :permission-mode 'yolo :non-interactive t)
  (harness-perms-test--call-with-skills
   (lambda (skills _linked _outside)
     (let ((probe (harness-perms-test--allowing-judge))
           (harness-perms-auto-model "judge:x"))
       (pcase-dolist (`(,tool ,kind ,path)
                      `(("write_file" write ,(expand-file-name "commit/SKILL.md" skills))
                        ("edit_file" write ,(expand-file-name "linked/SKILL.md" skills))
                        ("bash" exec ,skills)
                        ("spawn_agent" meta ,skills)
                        ("t_mystery" nil ,(expand-file-name "commit/SKILL.md" skills))))
         (ert-info ((format "%s %s" tool path))
           (let ((d (harness-perms-test--decide (harness-perms-test--request tool kind path))))
             (should (eq 'deny (plist-get d :behavior)))
             (should (plist-get d :final))
             (should (string-match-p "outside the allowed directories" (plist-get d :reason)))
             (should (string-search "It holds skills, which the tools that only read" (plist-get d :hint))))))
       (should (null (funcall probe 'requests))))
     ;; Nothing is granted on the way: asking for the directory waits for
     ;; the user, who is away, and the agent hears it may read it anyway.
     (let ((d (harness-perms-test--decide (harness-perms-test--dir-request skills "edit a skill"))))
       (should (eq 'deny (plist-get d :behavior)))
       (should (string-search "It holds skills" (plist-get d :hint))))
     ;; With the user there, a write asks for the directory, as anywhere
     ;; outside the roots.
     (setq harness-perms-test--session (plist-put harness-perms-test--session :non-interactive nil))
     (harness-perms-test--install-pending)
     (let ((started (harness-perms-test--start "write_file" 'write (expand-file-name "commit/SKILL.md" skills))))
       (should (equal (harness-perms-test--real (expand-file-name "commit" skills))
                      (plist-get (plist-get (cdr started) :payload) :dir)))
       (harness-call 'permission/answer "s1" (plist-get (cdr started) :id) "deny-once")
       (should (eq 'deny (plist-get (harness-test-await (car started)) :behavior)))))))

(ert-deftest harness-perms-skills-refuse-what-leads-out-at-once ()
  "A path in a skills directory that symbolic links lead out of it, or out
of the project that provides it, is refused at once, in every mode and
with the user there too: nobody is asked about a directory the agent
has tools for, and the agent is pointed to them.  A link committed to a
repository opens nothing."
  (harness-perms-test--setup)
  (harness-perms-test--install-pending)
  (harness-perms-test--call-with-skills
   (lambda (skills _linked outside)
     (let* ((cwd (plist-get harness-perms-test--session :cwd))
            (probe (harness-perms-test--allowing-judge))
            (harness-perms-auto-model "judge:x")
            (project (expand-file-name ".claude/skills/" cwd))
            (real (harness-perms-test--real outside))
            ;; What is read, the skills directory it is in, where it
            ;; leads and the directory a grant would need.
            (cases `(("read_file" ,(expand-file-name "commit/leak.txt" skills) ,skills
                      ,(concat real "secret.txt") ,real)
                     ("grep" ,(expand-file-name "commit/leak.txt" skills) ,skills
                      ,(concat real "secret.txt") ,real)
                     ("read_file" ,(expand-file-name "stolen/SKILL.md" project) ,project
                      ,(concat real "stolen/SKILL.md") ,(concat real "stolen/"))
                     ("list_dir" ,project ,project ,real ,real))))
       (harness-perms-test--each-mode
        (lambda (mode away)
          (pcase-dolist (`(,tool ,path ,dir ,target ,grant) cases)
            (ert-info ((format "%s %s in %s mode%s" tool path mode (if away ", user away" "")))
              (let ((d (harness-perms-test--decide (harness-perms-test--request tool 'read path))))
                (should (eq 'deny (plist-get d :behavior)))
                (should (plist-get d :final))
                (should (equal (format "%s is in the skills directory %s, but leads to %s, outside what may be read without approval"
                                       (abbreviate-file-name path) (abbreviate-file-name dir)
                                       (abbreviate-file-name (harness-path-normalize target)))
                               (plist-get d :reason)))
                (should (string-prefix-p harness-perms-skills-hint (plist-get d :hint)))
                (should (string-search "skill_load NAME" (plist-get d :hint)))
                (should (string-search (format "If the task needs %s itself, ask for it with request_directory_access."
                                               (abbreviate-file-name grant))
                                       (plist-get d :hint))))))))
       (should (null (funcall probe 'requests)))
       (should (null harness-perms-test--pending))
       ;; The project's directory is not one every call may read.
       (should-not (member project (plist-get (harness-call 'permission/rules "s1") :skills)))))))

(ert-deftest harness-perms-rules-beat-the-skills-allowance ()
  "A standing rule still decides first: a user who denied reading a
skills directory, or a tool, keeps it denied, refusals included."
  (harness-perms-test--setup :permission-mode 'auto :non-interactive t)
  (harness-perms-test--call-with-skills
   (lambda (skills _linked _outside)
     (let ((harness-perms-rules `((:path ,(concat skills "commit/**") :behavior deny)
                                  (:tool "file_info" :behavior deny))))
       (dolist (call `(("read_file" ,(expand-file-name "commit/SKILL.md" skills))
                       ("file_info" ,(expand-file-name "linked/SKILL.md" skills))
                       ("file_info" ,(expand-file-name "commit/leak.txt" skills))))
         (ert-info ((format "%s" call))
           (let ((d (harness-perms-test--decide (harness-perms-test--request (car call) 'read (cadr call)))))
             (should (eq 'deny (plist-get d :behavior)))
             (should (string-match-p "standing rule" (plist-get d :reason))))))
       (should (eq 'allow (harness-perms-test--behavior "read_file" 'read (expand-file-name "linked/SKILL.md" skills))))))))

(ert-deftest harness-perms-remote-skills-are-refused-at-once ()
  "A remote session's skills directories are on its host, not the ones
the harness serves on this machine: reading them is refused at once,
in every mode, and the agent is pointed to skill_load.  Nothing is
looked up on the host, and the rest of the host goes on as before."
  (let* ((home (harness-test-temp-dir))
         (process-environment (cons (concat "HOME=" (directory-file-name home)) process-environment)))
    (harness-perms-test--setup :permission-mode 'yolo :cwd "/home/u/proj/" :host "/ssh:u@box:")
    (harness-perms-test--install-pending)
    (harness-test-load-module 'skills)
    (make-directory (expand-file-name ".claude/skills/commit" home) t)
    (let ((harness-skills-directories '("~/.claude/skills" harness-skills-project-directories))
          (seen nil))
      ;; Discovery is asked about this machine only.
      (advice-add 'harness-skills--entries :before (lambda (cwd) (push cwd seen)) '((name . harness-perms-test)))
      (unwind-protect
          (harness-perms-test--each-mode
           (lambda (mode away)
             (dolist (path (list "/ssh:u@box:/home/u/.claude/skills/commit/SKILL.md"
                                 "/ssh:u@box:~/.claude/skills"
                                 "/ssh:u@box:/root/.claude/skills/x/y.md"
                                 (concat "/ssh:u@box:" home ".claude/skills/commit/SKILL.md")))
               (ert-info ((format "%s in %s mode%s" path mode (if away ", user away" "")))
                 (let ((d (harness-perms-test--decide (harness-perms-test--request "read_file" 'read path))))
                   (should (eq 'deny (plist-get d :behavior)))
                   (should (plist-get d :final))
                   (should (equal (format "%s is a skills directory on /ssh:u@box:, not the skills the harness serves, which are on this machine"
                                          path)
                                  (plist-get d :reason)))
                   (should (string-prefix-p harness-perms-skills-hint (plist-get d :hint)))
                   (should (string-search "request_directory_access only if the task is about the files of /ssh:u@box: itself"
                                          (plist-get d :hint))))))))
        (advice-remove 'harness-skills--entries 'harness-perms-test))
      (should seen)
      (should-not (delq nil seen))
      (should (null harness-perms-test--pending))
      ;; Elsewhere on the host, and in the project, as before.
      (should-not (harness-perms--skills-refusal
                   (harness-perms-test--request "read_file" 'read "/ssh:u@box:/home/u/notes/x.md")
                   (harness-perms-roots harness-perms-test--session)))
      (should (eq 'allow (harness-perms-test--behavior "read_file" 'read "/ssh:u@box:/home/u/proj/.claude/skills/a/SKILL.md"))))))

(ert-deftest harness-perms-bash-in-the-sandbox-is-refused-skills-it-cannot-see ()
  "A command run in the sandbox sees the skills directories it may read,
not where their links lead elsewhere: one naming such a path is refused
at once with the pointer to skill_load, rather than failing in there.
Unconfined, it sees what the user sees, and goes on as before."
  (harness-perms-test--setup :permission-mode 'yolo)
  (harness-perms-test--install-pending)
  (harness-perms-test--call-with-skills
   (lambda (skills linked outside)
     (let ((confined t)
           (leak (expand-file-name "commit/leak.txt" skills)))
       (harness-register-method 'sandbox/confined-p (lambda (_cwd) confined))
       (let ((d (harness-perms-test--decide (harness-perms-test--bash (format "cat %s ./README" leak)))))
         (should (eq 'deny (plist-get d :behavior)))
         (should (plist-get d :final))
         (should (equal (format "the command names %s, in the skills directory %s, but that leads to %s, which the sandbox does not show"
                                (abbreviate-file-name leak) (abbreviate-file-name skills)
                                (abbreviate-file-name (harness-path-normalize (expand-file-name "secret.txt" outside))))
                        (plist-get d :reason)))
         (should (string-prefix-p harness-perms-skills-hint (plist-get d :hint))))
       ;; What the sandbox shows runs.
       (dolist (command (list (format "cat %scommit/SKILL.md" skills)
                              (format "ls %s %s" (expand-file-name "linked" skills) linked)
                              "git status"))
         (should (eq 'allow (plist-get (harness-perms-test--decide (harness-perms-test--bash command)) :behavior))))
       ;; Unconfined, the command sees the link's target as the user does.
       (setq confined nil)
       (should (eq 'allow (plist-get (harness-perms-test--decide (harness-perms-test--bash (format "cat %s" leak)))
                                     :behavior)))
       (should (null harness-perms-test--pending))))))

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
    (should (equal '(:tool :kind :path :commands :input :behavior) (harness-test-option-keys type)))
    (harness-test-check-record-type type)
    (should (harness-test-fits-p type '(:tool "web_search" :behavior deny)))
    (should (harness-test-fits-p type '(:kind read :behavior allow)))
    (should (harness-test-fits-p type '(:tool "write_file" :path "/home/u/proj/lisp/**" :behavior allow)))
    (should (harness-test-fits-p type '(:tool "bash" :commands (("gcloud" "compute") ("gsutil")) :behavior allow)))
    (should (harness-test-fits-p type '(:behavior "deny")))
    (should (harness-test-fits-p (get 'harness-perms-rules 'custom-type)
                                 '((:tool "bash" :kind exec :behavior deny) (:behavior allow))))))

;;;; What a shell command reaches

(ert-deftest harness-perms-shell-ast-names-the-words-that-may-be-paths ()
  "The syntax tree says which words of a command line may name paths.
It keeps each command's arguments, the target of a redirection wherever
it stands, the words of a condition and the commands of a substitution,
and leaves out the programs and wrappers it runs."
  (let ((words (lambda (command)
                 (harness-perms--shell-ast-path-words
                  (harness-perms--shell-ast command)))))
    ;; A pipeline's programs are left out, the arguments kept.
    (should (equal '("-la" "/a b/c" "-5")
                   (funcall words "ls -la '/a b/c' | head -5")))
    ;; Quotes and backslashes are undone, comments left out.
    (should (equal '("say \"hi\" $x" "a b" "/etc/os-release")
                   (funcall words "echo \"say \\\"hi\\\" $x\" a\\ b # not /etc/passwd\ncat /etc/os-release")))
    ;; A redirection's target is a path wherever it stands.
    (should (equal '("/tmp/out" "1" "arg" "/tmp/log")
                   (funcall words ">/tmp/out cmd 2>&1 arg &>>/tmp/log")))
    ;; Assignments and wrapper options are kept, the programs not.
    (should (equal '("FOO=1" "-n" "BAR=2" "x.py" "-0" "/y")
                   (funcall words "FOO=1 sudo -n env BAR=2 /usr/bin/python3 x.py && if true; then xargs -0 rm /y; fi")))
    ;; A condition's words are candidates; a substitution runs commands.
    (should (equal '("-f" "/etc/foo" "ok")
                   (funcall words "[[ -f /etc/foo ]] && echo ok")))
    (should (equal '("x=$(cat /etc/hostname)" "y=`ls /srv`" "/etc/hostname" "/srv")
                   (funcall words "x=$(cat /etc/hostname) y=`ls /srv`")))
    (should (equal '("<(sort /a)" "/b" "/a" "$(date)" "/c" "`pwd`" "/d")
                   (funcall words "diff <(sort /a) /b; echo $(date) /c `pwd` /d")))
    ;; So are a loop's data and a case's patterns.
    (should (equal '("~/projects/*" "$f")
                   (funcall words "for f in ~/projects/*; do cat \"$f\"; done")))
    (should (equal '("$file" "/etc/passwd" "/etc/passwd")
                   (funcall words "case $file in /etc/passwd) cat /etc/passwd;; esac")))
    (should-not (harness-perms--shell-ast-path-words nil)))
  ;; The words that are paths: absolute, from home, or plainly relative.
  (should (equal "/etc/x" (harness-perms--path-word "/etc/x")))
  (should (equal "~/.claude" (harness-perms--path-word "$HOME/.claude")))
  (should (equal "~" (harness-perms--path-word "${HOME}")))
  (should (equal "/tmp/r.json" (harness-perms--path-word "--out=/tmp/r.json")))
  (should (equal "../lib" (harness-perms--path-word "LIB=../lib")))
  (should (equal "." (harness-perms--path-word ".")))
  (dolist (word '("src/a.el" "-la" ".git" "$HOMEDIR/x" "https://example.com/a" "origin/main"))
    (should-not (harness-perms--path-word word))))

(ert-deftest harness-perms-command-paths-are-the-files-it-names ()
  "A shell command's paths are the words naming files, made absolute; its programs are not."
  (let* ((s (harness-perms-test--setup))
         (cwd (harness-perms-test--real (plist-get s :cwd)))
         (nowhere "/harness-test-no-such-root")
         (paths (lambda (command) (harness-perms--command-paths (harness-perms-test--bash command)))))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :cwd cwd))
    (should-not (file-exists-p nowhere))
    ;; The call a judge doubted: it runs in the project and lists elsewhere.
    (should (equal (list (expand-file-name "~/.claude/projects/x"))
                   (funcall paths "ls -la ~/.claude/projects/x")))
    (should (equal (list (expand-file-name "~/.netrc") (expand-file-name "~/notes"))
                   (funcall paths "cat $HOME/.netrc \"${HOME}/notes\" ~/.netrc")))
    ;; Relative to where it runs; /dev/null and the like are nobody's.
    (should (equal (list (expand-file-name "lisp" cwd) (expand-file-name "../out.log" cwd))
                   (funcall paths "make -C ./lisp test > ../out.log 2>/dev/null </dev/zero")))
    (should (equal (list "/tmp/r.json") (funcall paths "/usr/bin/env python3 --out=/tmp/r.json")))
    (should (equal (list "/") (funcall paths "rm -rf /")))
    ;; An absolute word under no directory of this machine is no path,
    ;; such as what a grep looks for.
    (should (equal (list (directory-file-name cwd)) (funcall paths (format "grep -r %s/v1 ." nowhere))))
    (should-not (funcall paths "git status"))
    (should-not (funcall paths "printf '/etc\n/usr'"))
    ;; A substitution runs a command that names a path; a here-document's
    ;; body is data, and names nothing.
    (should (equal (list (expand-file-name "~/.ssh/key"))
                   (funcall paths "echo $(cat ~/.ssh/key)")))
    (should-not (funcall paths "cat <<EOF\n/etc/passwd\nEOF"))
    ;; Only a shell command has any.
    (should-not (harness-perms--command-paths (list :session harness-perms-test--session :tool "t" :kind 'read
                                                    :input '(:command "ls /etc") :paths (list cwd))))
    (should-not (harness-perms--command-paths (harness-perms-test--request "bash" 'exec cwd)))
    ;; On a remote host nothing is looked up, and only that host knows
    ;; where ~ is.
    (let ((harness-perms-test--session (list :id "s1" :cwd "/home/u/proj/" :host "/ssh:u@box:")))
      (should (equal (list "/ssh:u@box:/etc/hosts" "/ssh:u@box:/home/u/proj/a" (concat "/ssh:u@box:" nowhere "/x"))
                     (harness-perms--command-paths
                      (list :session harness-perms-test--session :tool "bash" :kind 'exec
                            :input (list :command (format "cat /etc/hosts ./a ~/b %s/x 2>/dev/null" nowhere))
                            :paths (list "/ssh:u@box:/home/u/proj"))))))))

(ert-deftest harness-perms-command-is-about-what-it-reaches-outside ()
  "A shell command is about the paths it names outside the session's directories.
When it names none there, it is about where it runs, as before."
  (let* ((s (harness-perms-test--setup))
         (cwd (harness-perms-test--real (plist-get s :cwd)))
         (outside (harness-perms-test--real (harness-test-temp-dir)))
         (subject (lambda (command) (harness-perms--subject-paths (harness-perms-test--bash command)))))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :cwd cwd))
    (should (equal (list cwd) (funcall subject "git status")))
    (should (equal (list cwd) (funcall subject "cp ./a ./b/c > ./log")))
    (should (equal (list outside) (funcall subject (format "ls -la %s" outside))))
    (should (equal (list (concat outside "a")) (funcall subject (format "cp %sa ./b" outside))))
    ;; A directory granted to the session is one of its own.
    (harness-call 'permission/allow-dir "s1" outside)
    (should (equal (list cwd) (funcall subject (format "cp %sa ./b" outside))))
    ;; Worked out once, a request carries it.
    (let ((r (harness-perms--with-reach (harness-perms-test--bash "cat /etc/hosts ./a"))))
      (should (equal (list "/etc/hosts" (expand-file-name "a" cwd)) (plist-get r :named-paths)))
      (should (equal (list "/etc/hosts") (plist-get r :subject-paths)))
      (should (eq r (harness-perms--with-reach r))))))

(ert-deftest harness-perms-command-prompt-is-about-what-it-reaches ()
  "A judge's doubt about what a command reads elsewhere names where it reads.
The prompt used to name, and offer as its pattern, the directory the
command runs in, while the judge spoke of another one.  It names what
the command reaches and where it runs; being about the call itself, it
offers no pattern, and remembering the answer holds for the commands it
runs (see `harness-perms-command-rule-prefixes')."
  (let* ((s (harness-perms-test--setup :permission-mode 'auto))
         (cwd (harness-perms-test--real (plist-get s :cwd)))
         (projects (file-name-as-directory (expand-file-name "projects" (harness-perms-test--real (harness-test-temp-dir)))))
         (judge (harness-perms-test--scripted-judge
                 (list '((:type text :delta "{\"decision\":\"deny\",\"reason\":\"it reads other projects' data\"}")
                         (:type done :stop-reason end-turn)))))
         (harness-perms-auto-model "judge:x"))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :cwd cwd))
    (make-directory projects)
    (harness-perms-test--install-pending)
    (let* ((p (harness-run-filter-async 'permission/decide (list :behavior 'ask)
                                        (harness-perms-test--bash (format "ls -la %sx 2>/dev/null" projects))))
           (pending (progn (harness-test-wait (lambda () harness-perms-test--pending) 2 "the judge's prompt")
                           (car harness-perms-test--pending)))
           (payload (plist-get pending :payload)))
      (should (equal "The permission judge would deny this call: it reads other projects' data"
                     (plist-get payload :reason)))
      ;; It names what the command reaches and where it runs, and has
      ;; no pattern: only a prompt about a directory has one.
      (should (equal (list (concat projects "x")) (plist-get payload :paths)))
      (should (equal cwd (plist-get payload :cwd)))
      (should-not (plist-member payload :pattern))
      ;; It says what a lasting answer would cover: ls, not every bash call.
      (should (equal '(("ls")) (plist-get payload :commands)))
      (should (equal "ls" (plist-get payload :covers)))
      ;; So does the list of waiting prompts.
      (let ((listed (plist-get (car (harness-call 'permission/pending "s1")) :payload)))
        (should (equal (list (concat projects "x")) (plist-get listed :paths)))
        (should (equal cwd (plist-get listed :cwd)))
        (should-not (plist-get listed :pattern)))
      (harness-call 'permission/answer "s1" (plist-get pending :id) "allow-session")
      (should (eq 'allow (plist-get (harness-test-await p) :behavior))))
    ;; The answer holds for ls, not for where the command reached.
    (should (equal (list (list :tool "bash" :commands '(("ls")) :behavior 'allow))
                   (gethash "s1" harness-perms--session-rules)))
    (should (= 1 (length (funcall judge))))
    ;; So another ls, reading there or staying in the project, runs
    ;; without the judge; a command that is not ls still asks.
    (dolist (command (list (format "ls %sx/a %sy" projects projects) "ls -la"))
      (let ((d (harness-perms-test--decide (harness-perms-test--bash command))))
        (should (eq 'allow (plist-get d :behavior)))
        (should (equal "allowed by a standing rule for bash (ls)" (plist-get d :reason)))))
    (should-not (harness-perms--find-rule (harness-perms-test--bash "git status")))
    (should (= 1 (length (funcall judge))))))

(ert-deftest harness-perms-command-rules-weigh-what-it-reaches ()
  "An allow rule holds a shell command when it holds what the command reaches outside.
A deny rule stops it for any path it runs in or names."
  (let* ((s (harness-perms-test--setup :permission-mode 'ask))
         (cwd (harness-perms-test--real (plist-get s :cwd)))
         (outside (harness-perms-test--real (harness-test-temp-dir)))
         (matches (lambda (rule command) (harness-perms--rule-matches-p rule (harness-perms-test--bash command)))))
    (setq harness-perms-test--session (plist-put harness-perms-test--session :cwd cwd))
    ;; Allowed in the project: what runs there and stays there, not
    ;; what reaches out of it.
    (let ((project (list :tool "bash" :path (concat cwd "**") :behavior 'allow)))
      (should (funcall matches project "git status"))
      (should (funcall matches project "make -C ./lisp > ./build.log"))
      (should-not (funcall matches project (format "ls %s" outside)))
      (should-not (funcall matches project "rm -rf ~")))
    ;; Allowed there: the commands reaching it from the project, and
    ;; only those.
    (let ((there (list :tool "bash" :path (concat outside "**") :behavior 'allow)))
      (should (funcall matches there (format "ls %s" outside)))
      (should (funcall matches there (format "cp %sa ./b" outside)))
      (should-not (funcall matches there "git status"))
      (should-not (funcall matches there (format "cp %sa ~/b" outside))))
    ;; Denied: any path named, inside the project too, or where it runs.
    (let ((secret '(:path "secret/**" :behavior deny)))
      (should (funcall matches secret "cat ./secret/key"))
      (should-not (funcall matches secret "cat ./README"))
      (should (harness-perms--rule-matches-p
               secret (list :session harness-perms-test--session :tool "bash" :kind 'exec
                            :input '(:command "ls") :paths (list (concat cwd "secret/"))))))
    (should (funcall matches (list :path (concat outside "**") :behavior 'deny) (format "cp ./a %sb" outside)))
    ;; Through the chain, the first rule that applies wins.
    (let ((harness-perms-rules (list '(:path "secret/**" :behavior deny)
                                     (list :tool "bash" :path (concat cwd "**") :behavior 'allow))))
      (should (eq 'deny (plist-get (harness-perms-test--decide (harness-perms-test--bash "cat ./secret/key")) :behavior)))
      (should (eq 'allow (plist-get (harness-perms-test--decide (harness-perms-test--bash "cat ./README")) :behavior)))
      ;; Nobody can answer here, so what no rule decides is denied.
      (let ((d (harness-perms-test--decide (harness-perms-test--bash (format "cat %sa" outside)))))
        (should (eq 'deny (plist-get d :behavior)))
        (should (equal "no user available" (plist-get d :reason)))))))

(ert-deftest harness-perms-shell-ast-finds-every-command-a-line-runs ()
  "A shell line is read into a syntax tree of the commands it runs.
Pipelines, substitutions, subshells, ifs, loops and case bodies are
walked; assignments, redirections, here-document bodies and comments
are not commands, and a wrapper's options are not its program."
  (let ((commands (lambda (command)
                    (mapcar (lambda (node)
                              (list (plist-get node :program)
                                    (plist-get node :command-words)))
                            (harness-perms--shell-ast-commands
                             (harness-perms--shell-ast command))))))
    (should (equal '(("gcloud" ("gcloud" "storage" "ls" "--project" "p"))
                     ("grep" ("grep" "running")))
                   (funcall commands "gcloud storage ls --project p | grep running")))
    ;; A wrapper runs the command after it, not itself.
    (should (equal '(("gcloud" ("gcloud" "storage" "ls")))
                   (funcall commands "FOO=1 sudo -u me -n gcloud storage ls")))
    (should (equal '(("gcloud" ("gcloud" "storage" "ls")))
                   (funcall commands "env -u HOME gcloud storage ls")))
    (should (equal '(("gcloud" ("gcloud" "storage" "ls")))
                   (funcall commands "timeout -s KILL 5 gcloud storage ls")))
    ;; Substitutions run commands, even in an assignment.
    (should (equal '(("gcloud" ("gcloud" "instances" "list"))
                     ("echo" ("echo" "yes")))
                   (funcall commands "x=$(gcloud instances list) y=1; echo yes")))
    (should (equal '(("gcloud" ("gcloud" "ls")) ("echo" ("echo" "yes")))
                   (funcall commands "if gcloud ls; then echo yes; fi")))
    (should (equal '(("gcloud" ("gcloud" "cp" "$f" "gs://b")))
                   (funcall commands "for f in a b; do gcloud cp \"$f\" gs://b; done")))
    ;; `do' in the list is data, not the loop's `do'.
    (should (equal '(("gcloud" ("gcloud" "ls")))
                   (funcall commands "for f in do re; do gcloud ls; done")))
    ;; A substitution in a redirection target runs a command too.
    (should (equal '(("echo" ("echo" "hi")) ("mktemp" ("mktemp")))
                   (funcall commands "echo hi > $(mktemp)")))
    ;; A quoted number is a word, not a file descriptor.
    (should (equal '(("echo" ("echo" "2")))
                   (funcall commands "echo \"2\">out")))
    (should (equal '(("gcloud" ("gcloud" "ls")))
                   (funcall commands "case x in a) gcloud ls;; esac")))
    (should (equal '(("cd" ("cd" "/x")) ("gcloud" ("gcloud" "ls"))
                     ("tee" ("tee" "log")))
                   (funcall commands "(cd /x && gcloud ls) 2>&1 | tee log")))
    ;; A condition runs no command, but a substitution in one does.
    (should (equal '(("gcloud" ("gcloud" "ls")))
                   (funcall commands "[[ -f x ]] && gcloud ls")))
    (should (equal '(("gcloud" ("gcloud" "ls")) ("gsutil" ("gsutil" "ls")))
                   (funcall commands "[[ -f x && \"$(gcloud ls)\" ]] && gsutil ls")))
    (should (equal '(("echo" ("echo" "ok")))
                   (funcall commands "[[ '$(gcloud ls)' ]] && echo ok")))
    (should (equal '(("gcloud" ("gcloud" "ls")))
                   (funcall commands "(( $(gcloud ls) ))")))
    ;; So do substitutions in a loop's data and a case's word or pattern.
    (should (equal '(("gcloud" ("gcloud" "ls")) ("echo" ("echo" "$f")))
                   (funcall commands "for f in $(gcloud ls); do echo $f; done")))
    (should (equal '(("gcloud" ("gcloud" "ls")) ("echo" ("echo" "x")))
                   (funcall commands "case $(gcloud ls) in a) echo x;; esac")))
    (should (equal '(("cat" ("cat")) ("echo" ("echo" "done")))
                   (funcall commands "cat <<EOF\ngcloud rm\ngsutil\nEOF\necho done")))
    ;; Comments are no commands, and quotes are undone, as words are.
    (should (equal '(("echo" ("echo" "hi")))
                   (funcall commands "echo hi # gcloud rm")))
    (should (equal '(("echo" ("echo" "a b" "x")))
                   (funcall commands "echo \"a b\" x")))
    ;; A function's body is read, though it runs only when called.
    (should (equal '(("gcloud" ("gcloud" "ls")) ("f" ("f")))
                   (funcall commands "function f { gcloud ls; }; f")))
    (should-not (harness-perms--shell-ast "   "))
    (should-not (harness-perms--shell-ast-commands nil))))

(ert-deftest harness-perms-command-rule-prefixes-keep-what-commands-share ()
  "A command rule begins at the program and keeps the words commands share.
A single command of a program gives the program alone; several give
their longest common subcommand, never an argument."
  (let ((prefixes (lambda (command) (harness-perms--command-rule-prefixes command))))
    (should (equal '(("gcloud")) (funcall prefixes "gcloud storage ls")))
    (should (equal '(("gcloud")) (funcall prefixes "gcloud compute instances list --project p")))
    (should (equal '(("gcloud" "compute" "instances"))
                   (funcall prefixes "gcloud compute instances list && gcloud compute instances describe x")))
    (should (equal '(("gcloud" "storage" "cp"))
                   (funcall prefixes "gcloud storage cp a b && gcloud storage cp c d")))
    ;; Arguments and options end the shared words.
    (should (equal '(("gcloud"))
                   (funcall prefixes "gcloud --project p compute list && gcloud --project q compute list")))
    (should (equal '(("git")) (funcall prefixes "git status && git log --oneline")))
    ;; Different programs each keep their own.
    (should (equal '(("gcloud") ("gsutil"))
                   (funcall prefixes "gcloud storage ls && gsutil ls")))
    (should (equal '(("gcloud") ("grep"))
                   (funcall prefixes "gcloud storage ls | grep running")))
    (should (equal '(("gcloud") ("gsutil") ("rm"))
                   (funcall prefixes "gcloud ls && gsutil ls && rm -rf x")))
    ;; The answer does not depend on the order the commands run in.
    (should (equal '(("gcloud") ("gsutil"))
                   (funcall prefixes "gsutil ls && gcloud ls")))
    ;; Wrappers are left out of what the rule names.
    (should (equal '(("gcloud")) (funcall prefixes "sudo -u me gcloud storage ls")))
    ;; An assignment's substitution is still a command.
    (should (equal '(("echo") ("gcloud"))
                   (funcall prefixes "x=$(gcloud instances list); echo hi")))
    ;; A line with no readable command has no rule.
    (should-not (funcall prefixes "   "))
    (should-not (funcall prefixes "FOO=1"))
    ;; Several patterns read as one phrase.
    (should (equal "gcloud and gsutil"
                   (harness-perms--command-pattern-title '(("gcloud") ("gsutil")))))
    (should (equal "gcloud compute instances"
                   (harness-perms--command-pattern-title '(("gcloud" "compute" "instances")))))
    (should (equal "gcloud, gsutil and rm"
                   (harness-perms--command-pattern-title '(("gcloud") ("gsutil") ("rm")))))))

(ert-deftest harness-perms-command-rules-match-the-commands-they-name ()
  "A command rule holds a shell call by what its command line runs.
An allow rule needs every command to match one of its patterns; a deny
rule needs any one.  A call the reader cannot read matches neither, and
a rule naming no commands still holds the whole tool."
  (let* ((session (list :id "s1" :cwd default-directory))
         (request (lambda (command)
                    (append (list :session session :tool "bash" :kind 'exec
                                  :paths (list default-directory))
                            (and command (list :input (list :command command))))))
         (matches (lambda (rule command)
                    (and (harness-perms--rule-matches-p rule (funcall request command)) t)))
         (allow '(:tool "bash" :commands (("gcloud")) :behavior allow))
         (sub '(:tool "bash" :commands (("gcloud" "compute")) :behavior allow))
         (deny '(:tool "bash" :commands (("gcloud")) :behavior deny)))
    (should (funcall matches allow "gcloud storage ls"))
    (should (funcall matches allow "sudo -u me gcloud storage ls > /tmp/out"))
    (should (funcall matches allow "/usr/local/bin/gcloud storage ls"))
    (should-not (funcall matches allow "gsutil ls"))
    (should-not (funcall matches allow "echo hi"))
    ;; Every command the line runs must match, or the rule is not enough.
    (should-not (funcall matches allow "gcloud storage ls && rm -rf x"))
    (should-not (funcall matches allow "gcloud storage ls | tee out"))
    (should (funcall matches sub "gcloud compute instances list"))
    (should (funcall matches sub "gcloud compute"))
    (should-not (funcall matches sub "gcloud storage ls"))
    (should-not (funcall matches sub "gcloud"))
    ;; A deny rule holds for any command it names.
    (should (funcall matches deny "gcloud storage ls"))
    (should (funcall matches deny "gcloud storage ls && gsutil ls"))
    (should-not (funcall matches deny "gsutil ls"))
    ;; No command line, no match: the rule cannot say what the call runs.
    (should-not (funcall matches allow nil))
    (should-not (funcall matches allow "FOO=1"))
    ;; A rule of the whole tool still holds every call of it.
    (should (funcall matches '(:tool "bash" :behavior allow) "gcloud storage ls"))
    (should (funcall matches '(:tool "bash" :behavior allow) "rm -rf x"))
    (should-not (funcall matches '(:tool "t_exec" :commands (("gcloud")) :behavior allow)
                         "gcloud storage ls"))
    ;; A pattern may be a program, a flat list of programs, or word lists.
    (should (funcall matches '(:tool "bash" :commands "gcloud" :behavior allow) "gcloud ls"))
    (should (funcall matches '(:tool "bash" :commands ("gcloud" "gsutil") :behavior allow) "gsutil ls"))
    (should (funcall matches '(:tool "bash" :commands ("gcloud") :behavior allow) "gcloud ls"))))

(ert-deftest harness-perms-command-answers-record-and-note-their-commands ()
  "A lasting answer to a shell call records a rule for its commands.
The prompt says what they are, the note words it, and another command
of the same programs runs without asking while one that is not is
still asked about."
  (harness-perms-test--with-notes
    (let ((p (harness-call 'tools/execute sid
                           (list :id "c1" :name "t_exec"
                                 :input '(:command "gcloud storage ls && gsutil ls")))))
      (harness-test-wait (lambda () (harness-call 'session/pending sid)) 2 "the prompt")
      (let ((payload (plist-get (car (harness-call 'session/pending sid)) :payload)))
        (should (equal '(("gcloud") ("gsutil")) (plist-get payload :commands)))
        (should (equal "gcloud and gsutil" (plist-get payload :covers))))
      (harness-call 'permission/answer sid
                    (plist-get (car (harness-call 'session/pending sid)) :id)
                    "allow-always")
      (should (equal "ran" (plist-get (harness-test-await p) :content))))
    (should (equal '((:tool "t_exec" :commands (("gcloud") ("gsutil")) :behavior allow))
                   harness-perms-rules))
    (let ((note (car (last (harness-perms-test--notes sid)))))
      (should (equal "Always allowing every t_exec call to gcloud and gsutil, in every session"
                     (plist-get note :content))))
    ;; The rule holds both programs, and only commands of them.
    (should (harness-perms--find-rule
             (plist-put (copy-sequence
                         (harness-perms-test--bash "sudo gcloud compute instances list && gsutil ls"))
                        :tool "t_exec")))
    (should-not (harness-perms--find-rule
                 (plist-put (copy-sequence (harness-perms-test--bash "gcloud ls && rm -rf x"))
                            :tool "t_exec")))
    ;; Undo takes the command rule back, not some other rule.
    (should (eq 'undone (car (harness-perms-test--undo sid (car (last (harness-perms-test--notes sid)))))))
    (should-not harness-perms-rules)
    ;; A single command's answer covers its program.
    (harness-perms-test--answered sid "t_exec" '(:command "gcloud compute instances list") "allow-session")
    (should (equal '((:tool "t_exec" :commands (("gcloud")) :behavior allow))
                   (gethash sid harness-perms--session-rules)))
    (should (equal "Allowing every t_exec call to gcloud for this session"
                   (plist-get (car (last (harness-perms-test--notes sid))) :content)))
    ;; A deny answer is scoped the same way.
    (harness-perms-test--answered sid "t_exec" '(:command "rm -rf build") "deny-always")
    (should (equal (list '(:tool "t_exec" :commands (("rm")) :behavior deny))
                   harness-perms-rules))
    (should (equal "Always denying every t_exec call to rm, in every session"
                   (plist-get (car (last (harness-perms-test--notes sid))) :content)))))

;;;; What a lasting answer covers

(ert-deftest harness-perms-rules-type-names-the-input-key ()
  "The settings page offers a rule's arguments, and accepts them."
  (require 'harness-test-helpers)
  (let ((type (cadr (get 'harness-perms-rules 'custom-type))))
    (should (memq :input (harness-test-option-keys type)))
    (should (harness-test-fits-p type '(:tool "bash" :input (:command "make test") :behavior allow)))
    (should (harness-test-fits-p type '(:tool "web_fetch" :input (:url "https://a.example/") :behavior deny)))))

(ert-deftest harness-perms-input-rules-hold-only-the-calls-with-those-arguments ()
  "A rule with `:input' holds a call that passes each of those arguments, equal.
The call's other arguments are free.  A different value, an argument
the call does not pass and an `:input' that is no plist of arguments
hold nothing, for a deny rule as for an allow rule; and the order the
rule lists them in makes no difference."
  (let* ((s (harness-perms-test--setup :permission-mode 'ask))
         (call (lambda (tool input)
                 (list :session s :tool tool :kind 'net :input input :paths nil :call-id (harness-short-id))))
         (matches (lambda (rule tool input)
                    (and (harness-perms--rule-matches-p rule (funcall call tool input)) t))))
    (let ((rule '(:tool "web_fetch" :input (:url "https://a.example/x") :behavior allow)))
      (should (funcall matches rule "web_fetch" '(:url "https://a.example/x")))
      (should (funcall matches rule "web_fetch" '(:url "https://a.example/x" :max_chars 10)))
      (should-not (funcall matches rule "web_fetch" '(:url "https://a.example/y")))
      (should-not (funcall matches rule "web_fetch" '(:max_chars 10)))
      (should-not (funcall matches rule "web_fetch" nil))
      (should-not (funcall matches rule "web_search" '(:url "https://a.example/x"))))
    ;; Every argument the rule names must match, numbers included.
    (let ((rule '(:tool "ssh" :input (:host "dev" :command "ls" :timeout 5) :behavior allow)))
      (should (funcall matches rule "ssh" '(:command "ls" :timeout 5 :host "dev")))
      (should-not (funcall matches rule "ssh" '(:command "ls" :timeout 6 :host "dev")))
      (should-not (funcall matches rule "ssh" '(:command "ls" :host "prod" :timeout 5))))
    ;; A deny rule holds the same calls, no more.
    (let ((rule '(:tool "web_fetch" :input (:url "https://a.example/x") :behavior deny)))
      (should (funcall matches rule "web_fetch" '(:url "https://a.example/x")))
      (should-not (funcall matches rule "web_fetch" '(:url "https://a.example/y"))))
    ;; Arguments that cannot be held hold no call, whatever the behavior.
    (dolist (bad '("https://a.example/x" (:url) (url "https://a.example/x") (:url "a" :max_chars)))
      (dolist (behavior '(allow deny))
        (should-not (funcall matches (list :tool "web_fetch" :input bad :behavior behavior)
                             "web_fetch" '(:url "https://a.example/x")))))
    ;; Two rules about the same arguments are one, in whatever order.
    (should (equal (harness-perms--rule-key '(:tool "ssh" :input (:host "dev" :command "ls") :behavior allow))
                   (harness-perms--rule-key '(:tool "ssh" :input (:command "ls" :host "dev") :behavior allow))))
    (should-not (equal (harness-perms--rule-key '(:tool "ssh" :input (:command "ls") :behavior allow))
                       (harness-perms--rule-key '(:tool "ssh" :behavior allow))))
    ;; Through the chain the rule allows that call and asks about no other.
    (let ((harness-perms-rules '((:tool "web_fetch" :input (:url "https://a.example/x") :behavior allow))))
      (let ((d (harness-perms-test--decide (funcall call "web_fetch" '(:url "https://a.example/x")))))
        (should (eq 'allow (plist-get d :behavior)))
        (should (equal "allowed by a standing rule for web_fetch whose url is exactly \"https://a.example/x\""
                       (plist-get d :reason))))
      (should (eq 'deny (plist-get (harness-perms-test--decide
                                    (funcall call "web_fetch" '(:url "https://a.example/y")))
                                   :behavior))))))

(ert-deftest harness-perms-input-rules-are-worded ()
  "What a rule about arguments is for is said in a few words, long texts cut."
  (should (equal "whose command is exactly \"make test\""
                 (harness-perms--input-title '(:command "make test"))))
  (should (equal "whose host is exactly \"dev\" and command is exactly \"ls\""
                 (harness-perms--input-title '(:host "dev" :command "ls"))))
  (should (equal "whose url is exactly \"u\", max_chars is exactly 20 and host is exactly \"h\""
                 (harness-perms--input-title '(:url "u" :max_chars 20 :host "h"))))
  (should (equal "whose command is exactly \"echo one…\""
                 (harness-perms--input-title '(:command "echo one\necho two"))))
  (should (equal (format "whose command is exactly \"%s…\"" (make-string 49 ?x))
                 (harness-perms--input-title (list :command (make-string 80 ?x)))))
  (should-not (harness-perms--input-title nil))
  (should-not (harness-perms--input-title '(:command)))
  (should (equal "bash whose command is exactly \"make test\""
                 (harness-perms--rule-subject '(:tool "bash" :input (:command "make test") :behavior allow))))
  (should (equal "calls whose url is exactly \"u\"" (harness-perms--rule-subject '(:input (:url "u") :behavior deny))))
  (should (equal "every bash call whose command is exactly \"make test\""
                 (harness-perms--recorded-what
                  (list :scope 'always :rule '(:tool "bash" :input (:command "make test") :behavior allow)))))
  (should (equal "edit_file calls in ~/proj/lisp/"
                 (harness-perms--recorded-what
                  (list :scope 'always :rule (list :tool "edit_file" :path (abbreviate-file-name "~/proj/lisp/")
                                                   :behavior 'allow))))))

(defun harness-perms-test--steps (ladder &optional key)
  "Return LADDER's step ids, or their KEY (`:label' or `:rule')."
  (mapcar (lambda (s) (plist-get s (or key :id))) (plist-get ladder :steps)))

(ert-deftest harness-perms-cover-ladder-of-a-shell-command ()
  "A shell prompt's covers go from the exact command to the whole tool.
They are the exact command line, the programs with the subcommands it
shares, what a lasting answer always held for, the programs alone and
the tool; steps that hold the same calls are one.  The step the answers
start on is the one an answer always held for."
  (let ((s (harness-perms-test--setup :permission-mode 'ask)))
    (ignore s)
    (let ((ladder (lambda (command) (harness-perms--cover-ladder (harness-perms-test--bash command)))))
      ;; One command of a program: its subcommands, then the program.
      (let ((l (funcall ladder "gcloud compute instances list --project p")))
        (should (equal '("exact" "subcommands" "programs" "tool") (harness-perms-test--steps l)))
        (should (equal '((:input (:command "gcloud compute instances list --project p"))
                         (:commands (("gcloud" "compute" "instances")))
                         (:commands (("gcloud")))
                         nil)
                       (harness-perms-test--steps l :rule)))
        (should (equal '("every bash call whose command is exactly \"gcloud compute instances list --project p\""
                         "every gcloud compute instances call (any arguments)"
                         "every gcloud call (any arguments)"
                         "every bash call (any command)")
                       (harness-perms-test--steps l :label)))
        ;; Starts where a lasting answer always held: the program.
        (should (equal "programs" (plist-get l :default))))
      ;; No subcommand to narrow by: the program is the narrowest command cover.
      (let ((l (funcall ladder "ls -la")))
        (should (equal '("exact" "programs" "tool") (harness-perms-test--steps l)))
        (should (equal "programs" (plist-get l :default))))
      ;; Several commands of one program keep the words they share, as before.
      (let ((l (funcall ladder "gcloud compute instances list && gcloud compute instances describe x")))
        (should (equal '("exact" "commands" "programs" "tool") (harness-perms-test--steps l)))
        (should (equal "commands" (plist-get l :default)))
        (should (equal '(:commands (("gcloud" "compute" "instances")))
                       (plist-get (nth 1 (plist-get l :steps)) :rule))))
      ;; Programs side by side: each keeps its own subcommands, or none.
      (let ((l (funcall ladder "gcloud storage ls | grep running")))
        (should (equal '("exact" "subcommands" "programs" "tool") (harness-perms-test--steps l)))
        (should (equal '((:commands (("gcloud" "storage" "ls") ("grep" "running")))
                         (:commands (("gcloud") ("grep"))))
                       (list (plist-get (nth 1 (plist-get l :steps)) :rule)
                             (plist-get (nth 2 (plist-get l :steps)) :rule))))
        (should (equal "programs" (plist-get l :default))))
      ;; Where a program runs several commands and another one, what
      ;; an answer always held for lies between the two.
      (let ((l (funcall ladder "gcloud compute instances list && gcloud compute instances describe x | grep running")))
        (should (equal '("exact" "subcommands" "commands" "programs" "tool") (harness-perms-test--steps l)))
        (should (equal '((:commands (("gcloud" "compute" "instances") ("grep" "running")))
                         (:commands (("gcloud" "compute" "instances") ("grep")))
                         (:commands (("gcloud") ("grep"))))
                       (mapcar (lambda (i) (plist-get (nth i (plist-get l :steps)) :rule)) '(1 2 3))))
        (should (equal "commands" (plist-get l :default))))
      ;; A line the reader cannot read: the line itself, or the tool.
      (let ((l (funcall ladder "FOO=1")))
        (should (equal '("exact" "tool") (harness-perms-test--steps l)))
        (should (equal "tool" (plist-get l :default))))
      ;; Whatever the default, it is a step of the ladder, and the usual
      ;; step is the rule an answer always recorded.
      (dolist (command '("make" "git status && git log --oneline" "sudo -u me gcloud storage ls"
                         "x=$(gcloud instances list); echo hi" "FOO=1"))
        (let* ((l (funcall ladder command))
               (usual (harness-perms--command-rule-prefixes command))
               (step (cl-find (plist-get l :default) (plist-get l :steps)
                              :key (lambda (s) (plist-get s :id)) :test #'equal)))
          (should step)
          (should (equal (and usual (list :commands usual)) (plist-get step :rule))))))))

(ert-deftest harness-perms-cover-ladder-starts-on-the-narrowest-when-asked ()
  "`harness-perms-default-cover' starts every ladder on its first step."
  (harness-perms-test--setup :permission-mode 'ask)
  (let ((harness-perms-default-cover 'narrowest))
    (should (equal "exact" (plist-get (harness-perms--cover-ladder (harness-perms-test--bash "make test")) :default)))
    (should (equal "path" (plist-get (harness-perms--cover-ladder
                                      (harness-perms-test--request "edit_file" 'write "/home/u/proj/a.el"))
                                     :default)))
    ;; A ladder of one is on its only step.
    (should (equal "tool" (plist-get (harness-perms--cover-ladder
                                      (list :session harness-perms-test--session :tool "spawn_agent" :kind 'meta
                                            :input (list :prompt (make-string 400 ?x))))
                                     :default))))
  (let ((harness-perms-default-cover 'usual))
    (should (equal "programs" (plist-get (harness-perms--cover-ladder (harness-perms-test--bash "make test")) :default)))
    (should (equal "tool" (plist-get (harness-perms--cover-ladder
                                      (harness-perms-test--request "edit_file" 'write "/home/u/proj/a.el"))
                                     :default)))))

(ert-deftest harness-perms-cover-ladder-of-a-call-on-files ()
  "A call that writes a file is covered by that file, its directory, the project or the tool.
The project is the session's working directory, offered when the file
lies below it; several files have the directory that holds them all."
  (harness-perms-test--setup :permission-mode 'ask :cwd "/home/u/proj/")
  (let ((ladder (lambda (tool kind &rest paths)
                  (harness-perms--cover-ladder (apply #'harness-perms-test--request tool kind paths)))))
    (let ((l (funcall ladder "edit_file" 'write "/home/u/proj/lisp/a.el")))
      (should (equal '("path" "dir" "project" "tool") (harness-perms-test--steps l)))
      (should (equal '((:path "/home/u/proj/lisp/a.el") (:path "/home/u/proj/lisp/") (:path "/home/u/proj/") nil)
                     (harness-perms-test--steps l :rule)))
      (should (equal '("every edit_file call on /home/u/proj/lisp/a.el"
                       "every edit_file call under /home/u/proj/lisp/ (any file)"
                       "every edit_file call under /home/u/proj/ (any file)"
                       "every edit_file call (any path)")
                     (harness-perms-test--steps l :label)))
      ;; What an answer always held for: every call of the tool.
      (should (equal "tool" (plist-get l :default))))
    ;; In the project's own directory the directory is the project.
    (should (equal '("path" "dir" "tool")
                   (harness-perms-test--steps (funcall ladder "write_file" 'write "/home/u/proj/README.md"))))
    ;; Outside the project (a granted directory): no project step.
    (should (equal '("path" "dir" "tool")
                   (harness-perms-test--steps (funcall ladder "write_file" 'write "/srv/notes/todo.org"))))
    ;; Several files: the directory holding them all, which here is the project.
    (let ((l (funcall ladder "write_file" 'write "/home/u/proj/lisp/a.el" "/home/u/proj/test/b.el")))
      (should (equal '("dir" "tool") (harness-perms-test--steps l)))
      (should (equal '(:path "/home/u/proj/") (plist-get (car (plist-get l :steps)) :rule))))
    (let ((l (funcall ladder "write_file" 'write "/home/u/proj/lisp/a.el" "/home/u/proj/lisp/sub/b.el")))
      (should (equal '("dir" "project" "tool") (harness-perms-test--steps l)))
      (should (equal '(:path "/home/u/proj/lisp/") (plist-get (car (plist-get l :steps)) :rule))))
    (should (equal '("path" "dir" "project" "tool")
                   (harness-perms-test--steps
                    (funcall ladder "write_file" 'write "/home/u/proj/lisp/a.el" "/home/u/proj/lisp/a.el"))))
    ;; Never the root of a file system, which would be every file.
    (should (equal '("path" "tool")
                   (harness-perms-test--steps (funcall ladder "write_file" 'write "/etc"))))
    ;; A directory is its own cover and holds everything below it.
    (should (equal '("dir" "project" "tool")
                   (harness-perms-test--steps (funcall ladder "list_dir" 'write "/home/u/proj/lisp/"))))
    ;; A remote file keeps its host; another host's files share nothing.
    (let ((l (funcall ladder "write_file" 'write "/ssh:u@box:/home/u/proj/a.el")))
      (should (equal '(:path "/ssh:u@box:/home/u/proj/") (plist-get (nth 1 (plist-get l :steps)) :rule))))
    (should (equal '("tool")
                   (harness-perms-test--steps (funcall ladder "write_file" 'write
                                                       "/ssh:u@box:/a/x" "/ssh:u@other:/a/y"))))
    ;; A call that is neither a read nor a write is not covered by paths,
    ;; but by its arguments.
    (let ((l (funcall ladder "spawn_agent" 'meta "/home/u/proj/")))
      (should (equal '("exact" "tool") (harness-perms-test--steps l)))
      (should (equal '(:input (:path "/home/u/proj/")) (plist-get (car (plist-get l :steps)) :rule))))))

(ert-deftest harness-perms-cover-ladder-of-any-other-call ()
  "Any other call is covered by its exact arguments or by the tool.
The exact arguments are all of them when each is a text or a number and
they are few; a shell-like tool pins its texts, not a timeout."
  (let ((s (harness-perms-test--setup :permission-mode 'ask))
        (ladder (lambda (tool kind input)
                  (harness-perms--cover-ladder
                   (list :session harness-perms-test--session :tool tool :kind kind :input input)))))
    (ignore s)
    (let ((l (funcall ladder "web_fetch" 'net '(:url "https://a.example/x" :max_chars 100))))
      (should (equal '("exact" "tool") (harness-perms-test--steps l)))
      (should (equal '((:input (:url "https://a.example/x" :max_chars 100)) nil) (harness-perms-test--steps l :rule)))
      (should (equal '("every web_fetch call whose url is exactly \"https://a.example/x\" and max_chars is exactly 100"
                       "every web_fetch call (any arguments)")
                     (harness-perms-test--steps l :label)))
      (should (equal "tool" (plist-get l :default))))
    ;; A shell-like call: its texts, not the timeout.
    (let ((l (funcall ladder "ssh" 'exec '(:host "dev" :command "uptime" :timeout 30))))
      (should (equal '("exact" "programs" "tool") (harness-perms-test--steps l)))
      (should (equal '(:input (:host "dev" :command "uptime")) (plist-get (car (plist-get l :steps)) :rule))))
    ;; No arguments, nothing to pin: the tool alone.
    (should (equal '("tool") (harness-perms-test--steps (funcall ladder "emacs_trace" 'write nil))))
    ;; Too long, or a list, an object or a flag among them: the tool alone.
    (should (equal '("tool") (harness-perms-test--steps (funcall ladder "spawn_agent" 'meta (list :prompt (make-string 400 ?x))))))
    (should (equal '("tool") (harness-perms-test--steps (funcall ladder "x" 'meta '(:names ("a" "b"))))))
    (should (equal '("tool") (harness-perms-test--steps (funcall ladder "x" 'meta '(:opts (:a 1))))))
    (should (equal '("tool") (harness-perms-test--steps (funcall ladder "x" 'meta '(:url "u" :fork t)))))
    (should (equal "every spawn_agent call (any arguments)"
                   (plist-get (car (plist-get (funcall ladder "spawn_agent" 'meta nil) :steps)) :label)))))

(ert-deftest harness-perms-prompt-carries-its-ladder ()
  "A prompt about a call lists its covers and says which one the answers start on.
The waiting prompts list them too, so a client that did not see the
request can still choose."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (let* ((p (harness-run-filter-async 'permission/decide (list :behavior 'ask)
                                      (harness-perms-test--bash "gcloud compute instances list --project p")))
         (payload (progn (harness-test-wait (lambda () harness-perms-test--pending) 2 "the prompt")
                         (plist-get (car harness-perms-test--pending) :payload))))
    (should (equal '("exact" "subcommands" "programs" "tool")
                   (mapcar (lambda (s) (plist-get s :id)) (plist-get payload :ladder))))
    (should (equal "every gcloud call (any arguments)"
                   (plist-get (cl-find "programs" (plist-get payload :ladder)
                                       :key (lambda (s) (plist-get s :id)) :test #'equal)
                              :label)))
    (should (equal "programs" (plist-get payload :cover)))
    ;; The steps the UI is told of say nothing of the rules they record.
    (should-not (cl-some (lambda (s) (plist-member s :rule)) (plist-get payload :ladder)))
    ;; What it said before stays: the commands and the words for them.
    (should (equal '(("gcloud")) (plist-get payload :commands)))
    (should (equal "gcloud" (plist-get payload :covers)))
    (harness-call 'permission/answer "s1" (plist-get (car harness-perms-test--pending) :id) "deny-once")
    (should (eq 'deny (plist-get (harness-test-await p) :behavior)))))

(ert-deftest harness-perms-answer-records-the-cover-it-names ()
  "A lasting answer holds for the step of the ladder it names, and is noted so.
Each step records its own rule; a step the prompt did not offer, or none,
is the one the prompt started on; an answer for this call alone records
nothing whatever it names.  Another call of the same kind then runs or
asks as the rule says."
  (harness-perms-test--with-notes
    (harness-define-tool "t_write" :label "Write" :kind 'write
                         :paths (lambda (in) (list (plist-get in :path)))
                         :handler (lambda (_in _ctx) "wrote"))
    (let* ((cwd (file-name-as-directory (file-truename (plist-get (harness-call 'session/get sid) :cwd))))
           (file (lambda (name) (expand-file-name name cwd)))
           (run (lambda (tool input answer)
                  (plist-get (harness-perms-test--answered sid tool input answer) :content)))
           (last-note (lambda () (plist-get (car (last (harness-perms-test--notes sid))) :content)))
           (rules-now (lambda () harness-perms-rules)))
      ;; The exact command line.
      (should (equal "ran" (funcall run "t_exec" '(:command "make test") '(:option "allow-always" :cover "exact"))))
      (should (equal '((:tool "t_exec" :input (:command "make test") :behavior allow)) (funcall rules-now)))
      (should (equal "Always allowing every t_exec call whose command is exactly \"make test\", in every session"
                     (funcall last-note)))
      ;; It holds that command alone: the next run needs no answer, another asks.
      (should (equal "ran" (plist-get (harness-test-await
                                       (harness-call 'tools/execute sid (list :id "again" :name "t_exec"
                                                                              :input '(:command "make test"))))
                                      :content)))
      (let ((d (harness-perms--find-rule (list :session (harness-call 'session/get sid) :tool "t_exec" :kind 'exec
                                               :input '(:command "make test -j4")))))
        (should-not d))
      ;; Undone, it is gone; the note says what it was.
      (should (equal '(undone . "Undone: no longer always allowing every t_exec call whose command is exactly \"make test\", in every session")
                     (harness-perms-test--undo sid (car (last (harness-perms-test--notes sid))))))
      (should-not (funcall rules-now))
      ;; A step that names programs.
      (funcall run "t_exec" '(:command "gcloud compute instances list") '(:option "allow-session" :cover "subcommands"))
      (should (equal '((:tool "t_exec" :commands (("gcloud" "compute" "instances")) :behavior allow))
                     (gethash sid harness-perms--session-rules)))
      (should (equal "Allowing every t_exec call to gcloud compute instances for this session" (funcall last-note)))
      (clrhash harness-perms--session-rules)
      ;; The whole tool.
      (funcall run "t_exec" '(:command "rm -rf build") '(:option "deny-always" :cover "tool"))
      (should (equal '((:tool "t_exec" :behavior deny)) (funcall rules-now)))
      (should (equal "Always denying every t_exec call, in every session" (funcall last-note)))
      (setq harness-perms-rules nil)
      ;; Not offered, or not named: the step the prompt started on.
      (funcall run "t_exec" '(:command "gcloud ls") '(:option "allow-always" :cover "nonsense"))
      (should (equal '((:tool "t_exec" :commands (("gcloud")) :behavior allow)) (funcall rules-now)))
      (setq harness-perms-rules nil)
      (funcall run "t_exec" '(:command "gcloud ls") "allow-always")
      (should (equal '((:tool "t_exec" :commands (("gcloud")) :behavior allow)) (funcall rules-now)))
      (setq harness-perms-rules nil)
      ;; For this call alone, nothing is recorded, whatever it names.
      (funcall run "t_exec" '(:command "make") '(:option "allow-once" :cover "tool"))
      (should-not (funcall rules-now))
      (should-not (gethash sid harness-perms--session-rules))
      ;; A call on a file: that file, its directory, the project.
      (should (equal "wrote" (funcall run "t_write" (list :path "lisp/a.el" :content "x")
                                      '(:option "allow-always" :cover "path"))))
      (should (equal (list (list :tool "t_write" :path (funcall file "lisp/a.el") :behavior 'allow)) (funcall rules-now)))
      (should (equal (format "Always allowing t_write calls in %s, in every session"
                             (abbreviate-file-name (funcall file "lisp/a.el")))
                     (funcall last-note)))
      (setq harness-perms-rules nil)
      (funcall run "t_write" (list :path "lisp/a.el" :content "x") '(:option "allow-session" :cover "dir"))
      (should (equal (list (list :tool "t_write" :path (funcall file "lisp/") :behavior 'allow))
                     (gethash sid harness-perms--session-rules)))
      ;; Any file of that directory runs now; one elsewhere asks.
      (should (equal "wrote" (plist-get (harness-test-await
                                         (harness-call 'tools/execute sid (list :id "w2" :name "t_write"
                                                                                :input (list :path "lisp/sub/b.el" :content "y"))))
                                        :content)))
      (should-not (harness-perms--find-rule
                   (list :session (harness-call 'session/get sid) :tool "t_write" :kind 'write
                         :paths (list (funcall file "test/c.el")))))
      (clrhash harness-perms--session-rules)
      ;; The exact arguments of a call that has no paths to narrow it.
      (funcall run "t_exec" '(:command "uptime") '(:option "allow-session" :cover "exact"))
      (should (equal '((:tool "t_exec" :input (:command "uptime") :behavior allow))
                     (gethash sid harness-perms--session-rules))))))

(ert-deftest harness-perms-a-cover-answer-with-input-is-undone-and-redone ()
  "A rule for exact arguments is a lasting decision like any other.
Undo takes back that rule alone, redo records it again, and a rule for
other arguments of the same tool is left as it is."
  (harness-perms-test--with-decisions
    (harness-perms-test--answered sid "t_exec" '(:command "make test") '(:option "allow-always" :cover "exact"))
    (let ((first (car (last (harness-perms-test--notes sid)))))
      (harness-perms-test--answered sid "t_exec" '(:command "make lint") '(:option "allow-always" :cover "exact"))
      (should (= 2 (length harness-perms-rules)))
      (should (eq 'undone (car (harness-perms-test--undo sid first))))
      ;; Only make test's rule went.
      (should (equal '((:tool "t_exec" :input (:command "make lint") :behavior allow)) harness-perms-rules))
      (should (equal '(done . "Redone: always allowing every t_exec call whose command is exactly \"make test\", in every session")
                     (harness-perms-test--redo sid first)))
      (should (= 2 (length harness-perms-rules)))
      (should (cl-find '(:command "make test") harness-perms-rules
                       :key (lambda (r) (plist-get r :input)) :test #'equal)))))

(ert-deftest harness-perms-answered-cover-rules-decide-later-calls ()
  "The next call meets the rule the answer recorded, through the whole chain."
  (harness-perms-test--with-notes
    (harness-perms-test--answered sid "t_exec" '(:command "make test") '(:option "allow-always" :cover "exact"))
    (let ((run (lambda (id command)
                 (harness-call 'tools/execute sid (list :id id :name "t_exec" :input (list :command command))))))
      ;; The very command runs without a question.
      (should (equal "ran" (plist-get (harness-test-await (funcall run "n1" "make test")) :content)))
      (should-not (harness-call 'session/pending sid))
      ;; A longer one is another call: it asks.
      (let ((p (funcall run "n2" "make test && rm -rf ~")))
        (harness-test-wait (lambda () (harness-call 'session/pending sid)) 2 "the prompt")
        (harness-call 'permission/answer sid (plist-get (car (harness-call 'session/pending sid)) :id) "deny-once")
        (should (plist-get (harness-test-await p) :denied))))))

;;;; Notes of lasting answers, and their undo

(defvar harness-perms-rules)
(defvar harness-allowed-directories)
(declare-function harness-session-flush "harness-session")
(declare-function harness-session--load-all "harness-session")

(defvar harness-perms-test--saved nil
  "(OPTION . VALUE) of every option saved, newest first.")

(defvar harness-perms-test--announced nil
  "The options `config/changed' announced, newest first.")

(defmacro harness-perms-test--with-notes (&rest body)
  "Run BODY with real sessions; `sid' is a fresh session in ask mode.
The saved rules and the allowed directories start empty, and saving
an option only records it in `harness-perms-test--saved'."
  (declare (indent 0))
  `(let ((harness-perms-rules nil)
         (harness-allowed-directories nil)
         (harness-perms-test--saved nil)
         (harness-perms-test--announced nil))
     (harness-test-with-temp-state
       (cl-letf (((symbol-function 'harness-save-user-option)
                  (lambda (sym value) (set sym value) (push (cons sym value) harness-perms-test--saved))))
         (unwind-protect
             (let ((sid (harness-perms-test--real-session 'ask)))
               (clrhash harness-perms--session-rules)
               (clrhash harness-perms--turn-dirs)
               (harness-on 'config/changed (lambda (key &rest _) (push key harness-perms-test--announced)))
               (harness-define-tool "t_exec" :label "Run" :kind 'exec :handler (lambda (_in _ctx) "ran"))
               (harness-define-tool "t_read" :label "Read" :kind 'read
                                    :paths (lambda (in) (list (plist-get in :path)))
                                    :handler (lambda (_in _ctx) "read"))
               ,@body)
           (clrhash harness-sessions))))))

(defun harness-perms-test--answered (sid tool input answer)
  "Run TOOL with INPUT in SID, answer its prompt with ANSWER; return the result.
The call goes into the transcript first, as the agent puts it there."
  (let* ((call-id (harness-short-id))
         (p (progn (harness-call 'session/append sid (list :kind 'tool-call :tool tool :call-id call-id :input input))
                   (harness-call 'tools/execute sid (list :id call-id :name tool :input input)))))
    (harness-test-wait (lambda () (harness-call 'session/pending sid)) 2 "the prompt")
    (harness-call 'permission/answer sid (plist-get (car (harness-call 'session/pending sid)) :id) answer)
    (harness-test-await p)))

(defun harness-perms-test--notes (sid)
  "Return the notes of lasting answers in SID's transcript, oldest first."
  (cl-remove-if-not #'harness-node-permission (harness-call 'session/nodes sid)))

(defun harness-perms-test--undo (sid note)
  "Undo the answer NOTE of SID tells of; return (OUTCOME . MESSAGE)."
  (let ((r (harness-call 'permission/undo sid (plist-get note :id))))
    (cons (plist-get r :outcome) (plist-get r :message))))

(defun harness-perms-test--record (sid note)
  "Return the record NOTE of SID holds now."
  (harness-node-permission (harness-call 'session/node sid (plist-get note :id))))

(ert-deftest harness-perms-lasting-answer-is-noted-and-undone ()
  "Always allow notes its rule under the call; undo takes back that rule only.
The call stays allowed, the note says it was undone, and undoing again
changes nothing."
  (harness-perms-test--with-notes
    (setq harness-perms-rules (list '(:tool "web_fetch" :behavior deny)))
    (let ((r (harness-perms-test--answered sid "t_exec" '(:command "make") "allow-always")))
      (should (equal "ran" (plist-get r :content))))
    (should (equal '((:tool "t_exec" :commands (("make")) :behavior allow) (:tool "web_fetch" :behavior deny)) harness-perms-rules))
    (let* ((nodes (harness-call 'session/nodes sid))
           (note (car (last nodes))))
      ;; Right under the call it answers, a hint the model never gets.
      (should (equal '(tool-call hint) (mapcar (lambda (n) (plist-get n :kind)) nodes)))
      (should (equal "Always allowing every t_exec call to make, in every session" (plist-get note :content)))
      (should (equal '(:scope always :rule (:tool "t_exec" :commands (("make")) :behavior allow) :undo offered)
                     (harness-node-permission note)))
      (should-not (string-match-p "Always allowing" (format "%S" (harness-call 'session/messages sid))))
      (setq harness-perms-test--saved nil harness-perms-test--announced nil)
      (should (equal '(undone . "Undone: no longer always allowing every t_exec call to make, in every session")
                     (harness-perms-test--undo sid note)))
      ;; Only that rule went, saved again, and an open settings page hears so.
      (should (equal '((:tool "web_fetch" :behavior deny)) harness-perms-rules))
      (should (equal (list (cons 'harness-perms-rules '((:tool "web_fetch" :behavior deny)))) harness-perms-test--saved))
      (should (memq 'harness-perms-rules harness-perms-test--announced))
      (let ((record (harness-perms-test--record sid note)))
        (should (eq 'undone (plist-get record :undo)))
        (should (equal "Undone: no longer always allowing every t_exec call to make, in every session"
                       (plist-get record :result))))
      ;; Undone once: the same rule recorded again since stays.
      (harness-perms-add-rule sid '(:tool "t_exec" :commands (("make")) :behavior allow) 'always)
      (should (eq 'undone (car (harness-perms-test--undo sid note))))
      (should (member '(:tool "t_exec" :commands (("make")) :behavior allow) harness-perms-rules)))
    ;; A once answer records nothing, and notes nothing.
    (harness-perms-test--answered sid "t_read" (list :path (expand-file-name "x" (harness-test-temp-dir))) "allow-once")
    (should (= 1 (length (harness-perms-test--notes sid))))
    ;; Nor is there a note to undo anywhere else.
    (should-error (harness-call 'permission/undo sid (plist-get (car (harness-call 'session/nodes sid)) :id)))))

(ert-deftest harness-perms-every-lasting-answer-is-noted ()
  "Each answer for the session or always notes what it recorded, and undo
takes that back from where it was recorded; the call keeps its answer."
  (harness-perms-test--with-notes
    (pcase-dolist (`(,answer ,text ,record ,denied)
                   '(("allow-session" "Allowing every t_exec call to make for this session"
                      (:scope session :rule (:tool "t_exec" :commands (("make")) :behavior allow)) nil)
                     ("deny-session" "Denying every t_exec call to make for this session"
                      (:scope session :rule (:tool "t_exec" :commands (("make")) :behavior deny)) t)
                     ("deny-always" "Always denying every t_exec call to make, in every session"
                      (:scope always :rule (:tool "t_exec" :commands (("make")) :behavior deny)) t)))
      (let ((r (harness-perms-test--answered sid "t_exec" '(:command "make") answer))
            (note (car (last (harness-perms-test--notes sid)))))
        (should (eq denied (and (plist-get r :denied) t)))
        (should (equal text (plist-get note :content)))
        (should (equal (append record '(:undo offered)) (harness-node-permission note)))
        (should (equal (list (plist-get record :rule))
                       (if (eq 'always (plist-get record :scope))
                           harness-perms-rules
                         (gethash sid harness-perms--session-rules))))
        (should (eq 'undone (car (harness-perms-test--undo sid note))))
        (should-not (gethash sid harness-perms--session-rules))
        (should-not harness-perms-rules)))
    (should (= 3 (length (harness-perms-test--notes sid))))))

(ert-deftest harness-perms-undo-leaves-a-rule-changed-since-alone ()
  "A rule changed in Settings after the answer stays as it is, and undo says so.
One saved again in another form, but saying the same, is still undone."
  (harness-perms-test--with-notes
    (harness-perms-test--answered sid "t_exec" '(:command "make") "allow-always")
    (let ((note (car (last (harness-perms-test--notes sid)))))
      ;; Edited on the settings page: the rule now denies those commands.
      (harness-call 'config/set 'harness-perms-rules
                    '((:tool "t_exec" :commands (("make")) :behavior deny)) :scope 'global)
      (setq harness-perms-test--saved nil)
      (should (equal '(changed . "Not undone: the saved rule for t_exec (make) has changed since (in Settings, say), so it stays as it is")
                     (harness-perms-test--undo sid note)))
      (should (equal '((:tool "t_exec" :commands (("make")) :behavior deny)) harness-perms-rules))
      (should-not harness-perms-test--saved)
      (let ((record (harness-perms-test--record sid note)))
        (should (eq 'changed (plist-get record :undo)))
        (should (string-prefix-p "Not undone" (plist-get record :result)))))
    ;; Saved again with its keys in another order and a string: the same rule.
    (setq harness-perms-rules nil)
    (harness-perms-test--answered sid "t_exec" '(:command "make") "allow-always")
    (setq harness-perms-rules (list '(:behavior "allow" :commands (("make")) :tool "t_exec")
                                    '(:tool "web_fetch" :behavior deny)))
    (should (eq 'undone (car (harness-perms-test--undo sid (car (last (harness-perms-test--notes sid)))))))
    (should (equal '((:tool "web_fetch" :behavior deny)) harness-perms-rules))))

(ert-deftest harness-perms-undo-when-the-rule-is-gone ()
  "Nothing to undo once the rule went: removed in Settings, or a session
rule lost when the harness restarted.  Nothing else is touched."
  (harness-perms-test--with-notes
    (harness-perms-test--answered sid "t_exec" '(:command "make") "allow-session")
    (clrhash harness-perms--session-rules)
    (should (equal '(gone . "Nothing to undo: this session has no such rule now (session rules end when the harness restarts, and a fork starts without them)")
                   (harness-perms-test--undo sid (car (last (harness-perms-test--notes sid))))))
    (harness-perms-test--answered sid "t_exec" '(:command "make") "allow-always")
    (setq harness-perms-rules (list '(:tool "web_fetch" :behavior deny)))
    (setq harness-perms-test--saved nil)
    (should (equal '(gone . "Nothing to undo: the saved rules no longer have one for t_exec (make)")
                   (harness-perms-test--undo sid (car (last (harness-perms-test--notes sid))))))
    (should (equal '((:tool "web_fetch" :behavior deny)) harness-perms-rules))
    (should-not harness-perms-test--saved)))

(ert-deftest harness-perms-note-offers-no-undo-for-nothing-new ()
  "A second prompt answered the same way adds nothing, so its note offers no undo."
  (harness-perms-test--with-notes
    (let* ((calls (mapcar (lambda (id)
                            (harness-call 'session/append sid (list :kind 'tool-call :tool "t_exec" :call-id id))
                            (harness-call 'tools/execute sid (list :id id :name "t_exec" :input nil)))
                          '("c1" "c2"))))
      (harness-test-wait (lambda () (= 2 (length (harness-call 'session/pending sid)))) 2 "two prompts")
      (dolist (pending (harness-call 'session/pending sid))
        (harness-call 'permission/answer sid (plist-get pending :id) "allow-session"))
      (dolist (p calls) (should (equal "ran" (plist-get (harness-test-await p) :content)))))
    (pcase-let ((`(,first ,second) (harness-perms-test--notes sid)))
      (should (eq 'offered (plist-get (harness-node-permission first) :undo)))
      (should (equal "Allowing every t_exec call for this session (already so: nothing new to undo)"
                     (plist-get second :content)))
      (should-not (plist-member (harness-node-permission second) :undo))
      (should (eq 'none (car (harness-perms-test--undo sid second))))
      (should (equal '((:tool "t_exec" :behavior allow)) (gethash sid harness-perms--session-rules))))))

(ert-deftest harness-perms-undo-reads-its-note-back-from-the-log ()
  "A note read back from the node log, its symbols strings, is undone the same."
  (harness-perms-test--with-notes
    (harness-perms-test--answered sid "t_exec" '(:command "make") "deny-always")
    ;; A restart: every node is read back from the session's log.
    (harness-session-flush)
    (clrhash harness-sessions)
    (harness-session--load-all)
    (let ((record (harness-node-permission (car (last (harness-perms-test--notes sid))))))
      (should (equal "always" (plist-get record :scope)))
      (should (equal "deny" (plist-get (plist-get record :rule) :behavior))))
    (should (eq 'undone (car (harness-perms-test--undo sid (car (last (harness-perms-test--notes sid)))))))
    (should-not harness-perms-rules)))

(ert-deftest harness-perms-directory-grants-are-noted-and-undone ()
  "A directory granted for the session or always is noted, and undo withdraws
that grant only; one changed since in Settings stays, and undo says so."
  (harness-perms-test--with-notes
    (let* ((cwd (plist-get (harness-call 'session/get sid) :cwd))
           (other (harness-test-temp-dir))
           (a (harness-test-temp-dir))
           (b (harness-test-temp-dir))
           (c (harness-test-temp-dir))
           (revoked nil)
           (read (lambda (dir answer)
                   (harness-perms-test--answered sid "t_read" (list :path (expand-file-name "f.txt" dir)) answer)
                   (car (last (harness-perms-test--notes sid))))))
      (ignore cwd)
      (harness-on 'permission/dir-revoked (lambda (_sid dir) (push dir revoked)))
      ;; For the session.
      (let ((note (funcall read a "allow-session")))
        (should (equal (format "Allowing %s for this session" (abbreviate-file-name a)) (plist-get note :content)))
        (should (equal (list :scope 'session :dir a :undo 'offered) (harness-node-permission note)))
        (should (equal (list a) (plist-get (harness-call 'session/get sid) :allowed-dirs)))
        (should (eq 'undone (car (harness-perms-test--undo sid note))))
        (should-not (plist-get (harness-call 'session/get sid) :allowed-dirs))
        (should (equal (list a) revoked))
        (should-not harness-allowed-directories))
      ;; Always, beside an entry of the user's.
      (setq harness-allowed-directories (list other))
      (let ((note (funcall read b "allow-always")))
        (should (equal (format "Always allowing %s, in every session" (abbreviate-file-name b))
                       (plist-get note :content)))
        (should (equal (list other b) harness-allowed-directories))
        (setq harness-perms-test--announced nil)
        (should (equal (cons 'undone (format "Undone: no longer always allowing %s, in every session"
                                             (abbreviate-file-name b)))
                       (harness-perms-test--undo sid note)))
        (should (equal (list other) harness-allowed-directories))
        (should (equal (cons 'harness-allowed-directories (list other)) (car harness-perms-test--saved)))
        (should (memq 'harness-allowed-directories harness-perms-test--announced)))
      ;; Written another way in Settings, the same directory: undone.
      (let ((note (funcall read c "allow-always")))
        (setq harness-allowed-directories (list other (directory-file-name c)))
        (should (eq 'undone (car (harness-perms-test--undo sid note))))
        (should (equal (list other) harness-allowed-directories)))
      ;; Changed in Settings to its parent, which still covers it: it stays.
      (let* ((d (file-name-as-directory (expand-file-name "sub" (harness-test-temp-dir))))
             (_ (make-directory d))
             (note (funcall read d "allow-always"))
             (parent (file-name-directory (directory-file-name d))))
        (setq harness-allowed-directories (list other parent))
        (should (equal (cons 'changed (format "Not undone: the allowed directories changed since (in Settings, say), and %s still covers %s, so they stay as they are"
                                              (abbreviate-file-name parent) (abbreviate-file-name d)))
                       (harness-perms-test--undo sid note)))
        (should (equal (list other parent) harness-allowed-directories))
        ;; Removed: nothing to undo.
        (setq harness-allowed-directories (list other))
        (let ((note (funcall read d "allow-always")))
          (setq harness-allowed-directories (list other))
          (should (equal (cons 'gone (format "Nothing to undo: %s is no longer among the allowed directories"
                                             (abbreviate-file-name d)))
                         (harness-perms-test--undo sid note))))))))

(ert-deftest harness-perms-directory-denials-and-requests-are-noted ()
  "Always deny for a path outside notes its rule; an agent's own request granted
for the session is noted too, but one granted until the turn ends is not."
  (harness-perms-test--with-notes
    (let* ((outside (harness-test-temp-dir))
           (pattern (concat outside "**")))
      (let ((r (harness-perms-test--answered sid "t_read" (list :path (expand-file-name "f" outside)) "deny-always"))
            (note (car (last (harness-perms-test--notes sid)))))
        (should (plist-get r :denied))
        (should (equal (list (list :path pattern :behavior 'deny)) harness-perms-rules))
        (should (equal (format "Always denying %s to every tool, in every session" (abbreviate-file-name pattern))
                       (plist-get note :content)))
        (should (equal (list :scope 'always :rule (list :path pattern :behavior 'deny) :undo 'offered)
                       (harness-node-permission note)))
        (should (eq 'undone (car (harness-perms-test--undo sid note))))
        (should-not harness-perms-rules))
      ;; The agent asks for a directory itself.
      (let ((request (harness-test-temp-dir)))
        (harness-perms-test--answered sid "request_directory_access" (list :path request :reason "Read it") "allow-once")
        (should (= 1 (length (harness-perms-test--notes sid))))
        ;; That grant ends with the turn; the next request asks again.
        (harness-emit 'agent/turn-ended sid)
        (harness-perms-test--answered sid "request_directory_access" (list :path request :reason "Read it") "allow-session")
        (let ((note (car (last (harness-perms-test--notes sid)))))
          (should (equal (list :scope 'session :dir (harness-perms-test--real request) :undo 'offered)
                         (harness-node-permission note)))
          (should (eq 'undone (car (harness-perms-test--undo sid note))))
          (should-not (plist-get (harness-call 'session/get sid) :allowed-dirs)))))))

;;;; Lasting answers as decisions: undo, redo, from any session

(defvar harness-decisions--entries)

(defmacro harness-perms-test--with-decisions (&rest body)
  "Run BODY as `harness-perms-test--with-notes' does, with the decisions kept."
  (declare (indent 0))
  `(harness-perms-test--with-notes
     (harness-test-load-module 'decisions)
     (setq harness-decisions--entries nil)
     ,@body))

(defun harness-perms-test--redo (sid note)
  "Redo the answer NOTE of SID tells of; return (OUTCOME . MESSAGE)."
  (let ((r (harness-call 'permission/redo sid (plist-get note :id))))
    (cons (plist-get r :outcome) (plist-get r :message))))

(ert-deftest harness-perms-lasting-answer-is-undone-then-redone ()
  "A lasting answer is a decision: undo takes its rule back, redo saves it
again, and undo takes it back again; its note follows every move."
  (harness-perms-test--with-decisions
    (setq harness-perms-rules (list '(:tool "web_fetch" :behavior deny)))
    (harness-perms-test--answered sid "t_exec" '(:command "make") "allow-always")
    (let* ((note (car (last (harness-perms-test--notes sid))))
           (id (harness-node-decision note))
           (decision (harness-call 'decision/get id)))
      (should id)
      (should (eq 'permission (plist-get decision :kind)))
      (should (eq 'done (plist-get decision :state)))
      (should (equal "Always allowing every t_exec call to make, in every session" (plist-get decision :text)))
      (should (equal sid (plist-get decision :session)))
      (should (equal (plist-get note :id) (plist-get decision :node)))
      ;; The note's own record is as it always was.
      (should (equal '(:scope always :rule (:tool "t_exec" :commands (("make")) :behavior allow) :undo offered)
                     (harness-node-permission note)))
      (should (equal '(undone . "Undone: no longer always allowing every t_exec call to make, in every session")
                     (harness-perms-test--undo sid note)))
      (should (equal '((:tool "web_fetch" :behavior deny)) harness-perms-rules))
      (should (eq 'undone (plist-get (harness-perms-test--record sid note) :undo)))
      (should (eq 'undone (plist-get (harness-call 'decision/get id) :state)))
      ;; Redo: the rule is saved again, and an open settings page hears so.
      (setq harness-perms-test--saved nil harness-perms-test--announced nil)
      (should (equal '(done . "Redone: always allowing every t_exec call to make, in every session")
                     (harness-perms-test--redo sid note)))
      (should (equal '((:tool "t_exec" :commands (("make")) :behavior allow) (:tool "web_fetch" :behavior deny)) harness-perms-rules))
      (should (eq 'harness-perms-rules (car (car harness-perms-test--saved))))
      (should (memq 'harness-perms-rules harness-perms-test--announced))
      (let ((record (harness-perms-test--record sid note)))
        (should (eq 'offered (plist-get record :undo)))
        (should (equal "Redone: always allowing every t_exec call to make, in every session" (plist-get record :result))))
      ;; Redoing what is in effect changes nothing.
      (should (eq 'done (car (harness-perms-test--redo sid note))))
      (should (= 2 (length harness-perms-rules)))
      ;; And undo works again.
      (should (eq 'undone (car (harness-perms-test--undo sid note))))
      (should (equal '((:tool "web_fetch" :behavior deny)) harness-perms-rules)))))

(ert-deftest harness-perms-redo-leaves-what-took-its-place ()
  "Redo records nothing over a rule recorded again, or changed, since the undo,
nor a session's rule once the session is gone: the decision ends there."
  (harness-perms-test--with-decisions
    ;; Recorded again by another answer.
    (harness-perms-test--answered sid "t_exec" '(:command "make") "allow-always")
    (let ((first (car (last (harness-perms-test--notes sid)))))
      (harness-perms-test--undo sid first)
      (harness-perms-test--answered sid "t_exec" '(:command "make") "allow-always")
      (should (equal '(changed . "Not redone: the saved rules have that rule for t_exec (make) again already")
                     (harness-perms-test--redo sid first)))
      (should (equal '((:tool "t_exec" :commands (("make")) :behavior allow)) harness-perms-rules))
      (should (eq 'changed (plist-get (harness-perms-test--record sid first) :undo)))
      ;; It ended: no undo either.  The later answer's note owns the rule.
      (should (eq 'changed (car (harness-perms-test--undo sid first))))
      (should (equal '((:tool "t_exec" :commands (("make")) :behavior allow)) harness-perms-rules))
      (should (eq 'undone (car (harness-perms-test--undo sid (car (last (harness-perms-test--notes sid))))))))
    ;; Changed after the undo.
    (setq harness-perms-rules nil)
    (harness-perms-test--answered sid "t_exec" '(:command "make") "deny-session")
    (let ((note (car (last (harness-perms-test--notes sid)))))
      (harness-perms-test--undo sid note)
      (puthash sid (list '(:tool "t_exec" :commands (("make")) :behavior allow)) harness-perms--session-rules)
      (should (equal '(changed . "Not redone: this session's rule for t_exec (make) has changed since, so it stays as it is")
                     (harness-perms-test--redo sid note)))
      (should (equal '((:tool "t_exec" :commands (("make")) :behavior allow)) (gethash sid harness-perms--session-rules))))
    ;; A session's rule needs its session.
    (clrhash harness-perms--session-rules)
    (harness-perms-test--answered sid "t_exec" '(:command "make") "allow-session")
    (let ((id (harness-node-decision (car (last (harness-perms-test--notes sid))))))
      (harness-call 'decision/undo id)
      (harness-call 'session/delete sid)
      (let ((r (harness-call 'decision/redo id)))
        (should (eq 'gone (plist-get r :outcome)))
        (should (equal "Nothing to redo: the session it was for is gone" (plist-get r :message))))
      (should-not (gethash sid harness-perms--session-rules)))))

(ert-deftest harness-perms-a-saved-answer-is-undone-and-redone-from-another-session ()
  "A saved rule's decision is the harness's: undone and redone from anywhere,
it changes what the calls of every session meet, and its note follows."
  (harness-perms-test--with-decisions
    (let ((other (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :permission-mode 'ask) :id))
          (run (lambda (session call-id)
                 (harness-call 'tools/execute session (list :id call-id :name "t_exec" :input '(:command "make"))))))
      (harness-perms-test--answered sid "t_exec" '(:command "make") "allow-always")
      (let ((id (harness-node-decision (car (last (harness-perms-test--notes sid))))))
        ;; The other session's call runs at once: the saved rule allows it.
        (should (equal "ran" (plist-get (harness-test-await (funcall run other "o1")) :content)))
        ;; Undone from elsewhere, the other session's chat say: it asks again.
        (should (eq 'undone (plist-get (harness-call 'decision/undo id) :outcome)))
        (should-not harness-perms-rules)
        (let ((p (funcall run other "o2")))
          (harness-test-wait (lambda () (harness-call 'session/pending other)) 2 "the prompt")
          (harness-call 'permission/answer other (plist-get (car (harness-call 'session/pending other)) :id) "deny-once")
          (should (plist-get (harness-test-await p) :denied)))
        ;; Redone from there: it runs at once again, and the first session's note says so.
        (should (eq 'done (plist-get (harness-call 'decision/redo id) :outcome)))
        (should (equal "ran" (plist-get (harness-test-await (funcall run other "o3")) :content)))
        (should (eq 'offered (plist-get (harness-perms-test--record sid (car (last (harness-perms-test--notes sid))))
                                        :undo)))))))

(ert-deftest harness-perms-directory-grants-are-redone ()
  "A directory grant undone is granted again by redo, for the session or
saved, unless something covers it by then."
  (harness-perms-test--with-decisions
    (let* ((a (harness-test-temp-dir))
           (b (harness-test-temp-dir))
           (read (lambda (dir answer)
                   (harness-perms-test--answered sid "t_read" (list :path (expand-file-name "f.txt" dir)) answer)
                   (car (last (harness-perms-test--notes sid))))))
      (let ((note (funcall read a "allow-session")))
        (should (eq 'undone (car (harness-perms-test--undo sid note))))
        (should-not (plist-get (harness-call 'session/get sid) :allowed-dirs))
        (should (equal (cons 'done (format "Redone: allowing %s for this session" (abbreviate-file-name a)))
                       (harness-perms-test--redo sid note)))
        (should (equal (list a) (plist-get (harness-call 'session/get sid) :allowed-dirs))))
      (let ((note (funcall read b "allow-always")))
        (harness-perms-test--undo sid note)
        (should-not harness-allowed-directories)
        (should (eq 'done (car (harness-perms-test--redo sid note))))
        (should (equal (list b) harness-allowed-directories))
        ;; Undone, then its parent allowed in Settings: redo leaves that be.
        (harness-perms-test--undo sid note)
        (let ((parent (file-name-directory (directory-file-name b))))
          (setq harness-allowed-directories (list parent))
          (should (equal (cons 'changed (format "Not redone: %s covers %s now, so the allowed directories stay as they are"
                                                (abbreviate-file-name parent) (abbreviate-file-name b)))
                         (harness-perms-test--redo sid note)))
          (should (equal (list parent) harness-allowed-directories)))))))

(ert-deftest harness-perms-a-note-from-before-decisions-is-taken-in ()
  "A note written before decisions were kept is undone, then redone, all the
same: it is taken into the decisions where it stands, and names its decision."
  (harness-perms-test--with-decisions
    (harness-perms-add-rule sid '(:tool "t_exec" :behavior allow) 'always)
    (let ((note (harness-call 'session/append sid
                              (list :kind 'hint :content "Always allowing every t_exec call, in every session"
                                    :meta (list :permission (list :scope 'always :rule '(:tool "t_exec" :behavior allow)
                                                                  :undo 'offered))))))
      (should (equal '(undone . "Undone: no longer always allowing every t_exec call, in every session")
                     (harness-perms-test--undo sid note)))
      (should-not harness-perms-rules)
      (let* ((id (harness-node-decision (harness-call 'session/node sid (plist-get note :id))))
             (decision (harness-call 'decision/get id)))
        (should (eq 'undone (plist-get decision :state)))
        (should (equal (plist-get note :id) (plist-get decision :node))))
      (should (eq 'done (car (harness-perms-test--redo sid note))))
      (should (equal '((:tool "t_exec" :behavior allow)) harness-perms-rules)))
    ;; One undone before decisions were kept is redone too.
    (setq harness-perms-rules nil)
    (let ((note (harness-call 'session/append sid
                              (list :kind 'hint :content "Always allowing every t_exec call, in every session"
                                    :meta (list :permission (list :scope 'always :rule '(:tool "t_exec" :behavior allow)
                                                                  :undo 'undone
                                                                  :result "Undone: no longer always allowing every t_exec call, in every session"))))))
      (should (eq 'done (car (harness-perms-test--redo sid note))))
      (should (equal '((:tool "t_exec" :behavior allow)) harness-perms-rules)))))

(ert-deftest harness-perms-a-call-an-answer-denies-names-its-decision ()
  "A call a lasting answer's rule denies, in any session, names the answer's
decision in its result, where the chat offers its undo; a rule no answer
in effect recorded names none."
  (harness-perms-test--with-decisions
    (let ((other (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :permission-mode 'ask) :id))
          (run (lambda (session call-id)
                 ;; As the agent does: the call, its result, then `agent/tool-result'.
                 (harness-call 'session/append session (list :kind 'tool-call :tool "t_exec" :call-id call-id))
                 (let* ((result (harness-test-await
                                 (harness-call 'tools/execute session (list :id call-id :name "t_exec" :input '(:command "make")))))
                        (node (harness-call 'session/append session
                                            (list :kind 'tool-result :call-id call-id
                                                  :output (plist-get result :content)
                                                  :is-error (plist-get result :is-error)
                                                  :meta (list :denied (plist-get result :denied))))))
                   (harness-emit 'agent/tool-result session node)
                   (harness-call 'session/node session (plist-get node :id))))))
      (harness-perms-test--answered sid "t_exec" '(:command "make") "deny-always")
      (let ((id (harness-node-decision (car (last (harness-perms-test--notes sid))))))
        (let ((node (funcall run other "o1")))
          (should (harness-json-true-p (plist-get (plist-get node :meta) :denied)))
          (should (equal id (harness-node-decided-by node))))
        ;; Undone, and the same rule saved again in Settings: no decision.
        (harness-call 'decision/undo id)
        (setq harness-perms-rules (list '(:tool "t_exec" :behavior deny)))
        (let ((node (funcall run other "o2")))
          (should (harness-json-true-p (plist-get (plist-get node :meta) :denied)))
          (should-not (harness-node-decided-by node)))))))

;;;; A policy

(ert-deftest harness-perms-policy-mode-and-non-interactive-are-every-sessions ()
  "A permission mode or non-interactive switch the policy sets wins over
what a session record says."
  (harness-perms-test--setup :permission-mode 'yolo :non-interactive nil)
  (harness-perms-test--install-pending)
  (let ((file (expand-file-name "x.txt" (plist-get harness-perms-test--session :cwd))))
    (should (eq 'allow (harness-perms-test--behavior "write_file" 'write file)))
    (harness-test-with-policy '((harness-permission-mode . ask) (harness-non-interactive . t))
      (should (eq 'ask (harness-perms--mode-of harness-perms-test--session)))
      (should (harness-perms--non-interactive-p harness-perms-test--session))
      (should (eq 'ask (plist-get (harness-call 'permission/rules "s1") :mode))))
    (harness-test-with-policy '((harness-permission-mode . ask))
      ;; The write asks now, as the session were in ask mode.
      (let ((s (harness-perms-test--start "write_file" 'write file)))
        (should-not (plist-get (plist-get (cdr s) :payload) :dir))
        (harness-call 'permission/answer "s1" (plist-get (cdr s) :id) "deny-once")
        (should (eq 'deny (plist-get (harness-test-await (car s)) :behavior)))))
    (should (eq 'allow (harness-perms-test--behavior "write_file" 'write file)))))

(ert-deftest harness-perms-policy-rules-come-first-and-answers-stay-in-the-session ()
  "Standing rules the policy sets come before a session's own, so no
answer overrides them; the prompts offer no answer for always, and one
given anyway holds for the session."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (let ((saved nil)
        (cwd (plist-get harness-perms-test--session :cwd)))
    (cl-letf (((symbol-function 'harness-save-user-option)
               (lambda (sym value) (push (cons sym value) saved))))
      (harness-perms-add-rule "s1" '(:tool "bash" :behavior allow) 'session)
      (should (eq 'allow (harness-perms-test--behavior "bash" 'exec)))
      (harness-test-with-policy '((harness-perms-rules (:tool "bash" :behavior deny)))
        (let ((d (harness-perms-test--decide (harness-perms-test--request "bash" 'exec))))
          (should (eq 'deny (plist-get d :behavior)))
          (should (string-match-p "standing rule" (plist-get d :reason))))
        (should (equal '(allow-once allow-session deny-once) (harness-perms--tool-options)))
        (let ((s (harness-perms-test--start "write_file" 'write (expand-file-name "f" cwd))))
          (should (equal '(allow-once allow-session deny-once)
                         (plist-get (plist-get (cdr s) :payload) :options)))
          (harness-call 'permission/answer "s1" (plist-get (cdr s) :id) "allow-always")
          (should (eq 'allow (plist-get (harness-test-await (car s)) :behavior))))
        ;; The answer holds for this session only.
        (should (equal '((:tool "bash" :behavior deny)) harness-perms-rules))
        (should (cl-find "write_file" (gethash "s1" harness-perms--session-rules)
                         :key (lambda (r) (plist-get r :tool)) :test #'equal))
        (harness-perms-add-rule "s1" '(:tool "elisp" :behavior deny) 'always)
        (should (equal '((:tool "bash" :behavior deny)) harness-perms-rules))
        ;; A directory prompt keeps deny-always only while the rules are free.
        (should (equal '(allow-once allow-session allow-always deny-once)
                       (harness-perms--dir-prompt-options harness-perms-dir-options))))
      (should-not saved)
      ;; Without the policy, the session's own rules come first again.
      (should (eq 'allow (harness-perms-test--behavior "bash" 'exec))))))

(ert-deftest harness-perms-policy-allowed-directories-are-not-added-to ()
  "Allowed directories the policy sets are what every session reaches
besides its own: no prompt offers allow-always, an answer for always
grants to the session, and none of them is revoked."
  (let ((saved nil)
        (fixed (harness-test-temp-dir))
        (outside (harness-test-temp-dir))
        (harness-allowed-directories nil))
    (harness-test-with-temp-state
      (harness-perms-test--setup :permission-mode 'ask)
      (harness-perms-test--install-pending)
      (cl-letf (((symbol-function 'harness-save-user-option)
                 (lambda (sym value) (set sym value) (push (cons sym value) saved))))
        (harness-test-with-policy `((harness-allowed-directories ,fixed))
          (should (member fixed (harness-call 'permission/allowed-dirs "s1")))
          (let ((s (harness-perms-test--start "read_file" 'read (expand-file-name "f" outside))))
            (should (equal '(allow-once allow-session deny-once deny-always)
                           (plist-get (plist-get (cdr s) :payload) :options)))
            (harness-call 'permission/answer "s1" (plist-get (cdr s) :id) "allow-always")
            (should (eq 'allow (plist-get (harness-test-await (car s)) :behavior))))
          ;; Granted to the session, not added to the policy's list.
          (should (member outside (harness-call 'permission/allowed-dirs "s1")))
          (should (equal (list fixed) harness-allowed-directories))
          (should-not saved)
          (should (string-match-p "set by policy"
                                  (cadr (should-error (harness-call 'permission/allow-dir "s1"
                                                                    (harness-test-temp-dir) 'always)))))
          (should-error (harness-call 'permission/revoke-dir "s1" fixed))
          (let ((entries (harness-call 'permission/dirs "s1")))
            (should-not (plist-get (cl-find 'config entries :key (lambda (e) (plist-get e :source)))
                                   :revocable))
            (should (plist-get (cl-find 'session entries :key (lambda (e) (plist-get e :source)))
                               :revocable)))
          ;; An agent's own request is answered the same way.
          (let* ((wanted (harness-test-temp-dir))
                 (s (harness-perms-test--start-request wanted "Read the docs")))
            (should-not (memq 'allow-always (plist-get (plist-get (cdr s) :payload) :options)))
            (let ((d (harness-call 'permission/answer "s1" (plist-get (cdr s) :id) "allow-always")))
              (should (eq 'allow (plist-get d :behavior)))
              (should (string-match-p "to this session" (plist-get d :reason)))))
          (should (equal (list fixed) harness-allowed-directories))
          (should-not saved))))))

;;;; session_settings

(defun harness-perms-test--settings-request (input)
  "Return a permission request for a session_settings call with INPUT."
  (list :session harness-perms-test--session :tool "session_settings" :kind 'meta
        :input input :paths nil :call-id (harness-short-id)))

(ert-deftest harness-perms-session-settings-read-needs-no-approval ()
  "A session_settings read is the read it is: ask mode and accept-edits
allow it without the user, the judge never sees it, and no prompt is
made.  A set changes harness state: ask mode asks about it, as it asks
about session_send and session_control."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--install-pending)
  (let ((read (harness-perms-test--settings-request '(:action "read"))))
    (should (eq 'read (harness-perms--call-kind read)))
    (should (eq 'allow (plist-get (harness-perms-test--decide read) :behavior)))
    (should-not harness-perms-test--pending))
  (let* ((set (harness-perms-test--settings-request '(:action "set" :model "demo:x")))
         (p (harness-run-filter-async 'permission/decide (list :behavior 'ask) set)))
    (should (eq 'meta (harness-perms--call-kind set)))
    (harness-test-wait (lambda () harness-perms-test--pending) 2 "the prompt for the set")
    (let ((pending (car harness-perms-test--pending)))
      (should (equal "session_settings" (plist-get (plist-get pending :payload) :tool)))
      (should (equal harness-perms-options (plist-get (plist-get pending :payload) :options)))
      (harness-call 'permission/answer "s1" (plist-get pending :id) "allow-once"))
    (should (eq 'allow (plist-get (harness-test-await p) :behavior)))))

(ert-deftest harness-perms-session-settings-in-accept-edits-and-under-a-rule ()
  "Accept-edits accepts a read and still asks about a set; a standing
deny rule comes first and denies a read ask mode would allow; an action
the module does not know is no read."
  (harness-perms-test--setup :permission-mode 'accept-edits)
  (let ((read (harness-perms-test--settings-request '(:action "read")))
        (set (harness-perms-test--settings-request '(:action "set" :thinking "low"))))
    (should (eq 'allow (plist-get (harness-perms--mode-decision nil read) :behavior)))
    (should-not (plist-get (harness-perms--mode-decision nil set) :behavior)))
  (setq harness-perms-rules (list (list :tool "session_settings" :behavior 'deny)))
  (let ((d (harness-perms-test--decide (harness-perms-test--settings-request '(:action "read")))))
    (should (eq 'deny (plist-get d :behavior)))
    (should (string-match-p "standing rule" (plist-get d :reason))))
  (should (eq 'meta (harness-perms--call-kind
                     (harness-perms-test--settings-request '(:action "frob"))))))

;;;; Denied calls the user can approve

(defvar harness-perms-test--ran nil
  "Inputs the approvable test tool ran with, newest first.")

(defun harness-perms-test--tool ()
  "Define the call the approval tests deny and the user then approves."
  (harness-define-tool "t_approved"
    :label "Approvable test call"
    :description "A call the tests deny and the user then approves."
    :kind 'exec
    :handler (lambda (input _ctx)
               (push input harness-perms-test--ran)
               (harness-tool-ok "ran it"))))

(defun harness-perms-test--deny (id &optional tool input)
  "Have SESSION s1 denied a call TOOL (default t_approved) with INPUT.
Return the result of the call, the tool being denied by a standing
rule.  The rule and the call are of this session."
  (let ((tool (or tool "t_approved"))
        (input (or input '(:command "x"))))
    (harness-perms-add-rule "s1" (list :tool tool :behavior 'deny) 'session)
    (prog1 (harness-test-await (harness-call 'tools/execute "s1" (list :id id :name tool :input input)))
      (setq harness-perms--session-rules (make-hash-table :test 'equal)))))

(ert-deftest harness-perms-denied-call-gets-a-handle ()
  "Every denial is kept under the handle of its call id, with the tool
and the very input it was denied with; the denial the agent reads names
the handle and how the user can approve it."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--tool)
  (setq harness-perms-test--ran nil)
  (let* ((result (harness-perms-test--deny "call-1"))
         (record (harness-perms--denied-record "s1" "call-1")))
    (should (plist-get result :denied))
    (should-not harness-perms-test--ran)
    (should (string-match-p "\\`Denied: denied by a standing rule" (plist-get result :content)))
    (should (string-match-p "handle call-1" (plist-get result :content)))
    (should (string-match-p "rerun_approved" (plist-get result :content)))
    (should record)
    (should (equal "t_approved" (plist-get record :tool)))
    (should (equal '(:command "x") (plist-get record :input)))
    (should-not (plist-get record :approved))
    (should-not (plist-get record :used))
    ;; A handle this session never had, and one of another session, are unknown.
    (should-not (harness-perms--denied-record "s1" "nope"))
    (should-not (harness-perms--denied-record "s2" "call-1"))
    ;; A call the chain allows is no denied call.
    (harness-perms-test--setup :permission-mode 'yolo)
    (harness-test-await (harness-call 'tools/execute "s1"
                                      (list :id "call-2" :name "t_approved" :input '(:command "y"))))
    (should-not (harness-perms--denied-record "s1" "call-2"))))

(ert-deftest harness-perms-approving-denied-call-tells-the-agent ()
  "Only the user approves a denied call, and the agent is told to rerun
it with its handle.  Approving again tells it again; an unknown handle
is an error, and a blank one is no handle at all."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--tool)
  (let* ((prompts (harness-perms-test--prompts))
         (call (lambda (handle)
                 (harness-call 'permission/approve-denied "s1" handle)))
         (unapproved (harness-perms-test--deny "call-1")))
    (should (plist-get unapproved :denied))
    ;; Nothing was approved: rerunning is refused and runs nothing.
    (setq harness-perms-test--ran nil)
    (let ((refused (harness-test-await
                    (harness-call 'tools/execute "s1"
                                  (list :id "r0" :name "rerun_approved" :input '(:handle "call-1"))))))
      (should (plist-get refused :is-error))
      (should (string-match-p "has not been approved by the user" (plist-get refused :content)))
      (should-not harness-perms-test--ran))
    (should-not (funcall prompts))
    ;; The user approves: the record says so and the agent is told.
    (let ((answer (funcall call "call-1")))
      (should (plist-get answer :approved))
      (should (equal "t_approved" (plist-get answer :tool)))
      (should (plist-get (harness-perms--denied-record "s1" "call-1") :approved))
      (should (equal (list (cons "s1" (format harness-perms-approved-text "t_approved" "call-1")))
                     (funcall prompts)))
      (should (string-match-p "\\`The user approved" (cdar (funcall prompts)))))
    ;; Approving it again tells the agent again.
    (funcall call "call-1")
    (should (= 2 (length (funcall prompts))))
    (should (string-match-p "Run it now, unchanged, with rerun_approved"
                            (cdar (funcall prompts))))
    ;; An unknown or blank handle is an error.
    (should-error (funcall call "nope"))
    (should-error (funcall call ""))
    (should-error (funcall call nil))
    (should-error (harness-call 'permission/approve-denied "s2" "call-1"))))

(ert-deftest harness-perms-approved-call-runs-with-no-permission-check ()
  "Rerunning the approved call runs the stored tool with the stored input
and asks the permission chain nothing: the rule that denied it still
stands, and a second permission decision is never made."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--tool)
  (let* ((prompts (harness-perms-test--prompts))
         (decisions nil)
         (harness-perms-test--ran nil))
    (harness-on 'permission/decided (lambda (_sid request _decision)
                                      (push (plist-get request :tool) decisions)))
    (harness-perms-test--deny "call-1")
    (harness-call 'permission/approve-denied "s1" "call-1")
    (setq decisions nil)
    (let* ((result (harness-test-await
                    (harness-call 'tools/execute "s1"
                                  (list :id "r1" :name "rerun_approved" :input '(:handle "call-1")))))
           (record (harness-perms--denied-record "s1" "call-1")))
      (should-not (plist-get result :is-error))
      (should (string-match-p "The user approved denied call call-1 (t_approved); it ran as it was denied"
                              (plist-get result :content)))
      (should (string-match-p "ran it" (plist-get result :content)))
      ;; The tool ran with the input it was denied with, once.
      (should (equal '((:command "x")) harness-perms-test--ran))
      ;; Nothing decided the stored call again: only rerun_approved went
      ;; through the chain, and it never needs approval.
      (should (equal '("rerun_approved") decisions))
      ;; The handle is used up, and the rerun is linked to the call.
      (should (plist-get record :used))
      (should (equal '(:user-approved t :rerun-of "call-1" :rerun-tool "t_approved")
                     (harness-plist-get-in result '(:meta))))
      ;; The agent can work on with its output; the user's approval stands.
      (should (equal "s1" (caar (funcall prompts)))))))

(ert-deftest harness-perms-rerun-refuses-used-and-unknown-handles ()
  "A handle is used once, and only a denied call of this session can be
rerun.  An unknown handle, another session's, and a used one are
refused, and nothing runs."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--tool)
  (harness-perms-test--prompts)
  (let ((harness-perms-test--ran nil))
    (harness-perms-test--deny "call-1")
    (harness-call 'permission/approve-denied "s1" "call-1")
    (let ((first (harness-test-await
                  (harness-call 'tools/execute "s1"
                                (list :id "r1" :name "rerun_approved" :input '(:handle "call-1"))))))
      (should-not (plist-get first :is-error)))
    (setq harness-perms-test--ran nil)
    (dolist (case '(("call-1" . "already rerun")
                    ("nope" . "No denied call nope")
                    ("" . "needs handle")))
      (let ((result (harness-test-await
                     (harness-call 'tools/execute "s1"
                                   (list :id "r2" :name "rerun_approved"
                                         :input (list :handle (car case)))))))
        (should (plist-get result :is-error))
        (should (string-match-p (cdr case) (plist-get result :content)))))
    (should-not harness-perms-test--ran)
    ;; A handle of a call another session was denied is not this one's.
    (harness-perms-add-rule "s1" '(:tool "t_approved" :behavior deny) 'session)
    (harness-test-await (harness-call 'tools/execute "s2"
                                      (list :id "other" :name "t_approved" :input '(:command "z"))))
    (harness-perms-add-rule "s2" '(:tool "t_approved" :behavior deny) 'session)
    (harness-call 'permission/approve-denied "s2" "other")
    (let ((result (harness-test-await
                   (harness-call 'tools/execute "s1"
                                 (list :id "r3" :name "rerun_approved" :input '(:handle "other"))))))
      (should (plist-get result :is-error))
      (should (string-match-p "No denied call other" (plist-get result :content))))
    (should-not harness-perms-test--ran)))

(ert-deftest harness-perms-rerun-cannot-change-the-call ()
  "rerun_approved takes the handle alone: the tool and its arguments are
the stored ones, whatever else the call carries, and the stored call is
the one that runs."
  (harness-perms-test--setup :permission-mode 'ask)
  (harness-perms-test--tool)
  (harness-perms-test--prompts)
  (let ((harness-perms-test--ran nil))
    (harness-perms-test--deny "call-1" "t_approved" '(:command "harmless"))
    (harness-perms-add-rule "s1" '(:tool "t_other" :behavior deny) 'session)
    (harness-define-tool "t_other" :label "Other" :kind 'exec
                         :handler (lambda (_input _ctx) (harness-tool-ok "the other one")))
    (harness-call 'permission/approve-denied "s1" "call-1")
    ;; A call that tries to pass another tool and another input: both are
    ;; ignored, the stored call runs.
    (let ((result (harness-test-await
                   (harness-call 'tools/execute "s1"
                                 (list :id "r1" :name "rerun_approved"
                                       :input '(:handle "call-1" :name "t_other"
                                                :tool "t_other" :input (:command "rm -rf /")))))))
      (should-not (plist-get result :is-error))
      (should (equal '((:command "harmless")) harness-perms-test--ran))
      (should-not (string-match-p "the other one" (plist-get result :content)))
      (should (string-match-p "the tool and the input are the call's own"
                              (harness-tool-description (harness-tool-get "rerun_approved")))))))

(ert-deftest harness-perms-a-final-gate-denial-gets-a-handle ()
  "A denial a gate makes at its own priority, `:final' and before the
mode, is kept and approvable all the same: the record hangs off
`permission/decided', so it sees every stage's denials, the write-up
gate's and the supervisor's included."
  (harness-perms-test--setup :permission-mode 'yolo)
  (harness-perms-test--tool)
  (let ((gate (lambda (_decision next request)
                (funcall next (if (equal "t_approved" (plist-get request :tool))
                                  (list :behavior 'deny :final t
                                        :reason "this session writes a task up rather than doing it, so it only reads"
                                        :hint "Write it up from what you can read.")
                                _decision)))))
    (harness-add-filter 'permission/decide gate 25)
    (unwind-protect
        (let ((harness-perms-test--ran nil))
          ;; yolo would allow it; the gate's denial is final and wins.
          (let ((result (harness-test-await
                         (harness-call 'tools/execute "s1"
                                       (list :id "call-gate" :name "t_approved" :input '(:command "x"))))))
            (should (plist-get result :denied))
            (should (string-match-p "handle call-gate" (plist-get result :content)))
            (should-not harness-perms-test--ran))
          (harness-perms-test--prompts)
          (harness-call 'permission/approve-denied "s1" "call-gate")
          (let ((rerun (harness-test-await
                        (harness-call 'tools/execute "s1"
                                      (list :id "r1" :name "rerun_approved" :input '(:handle "call-gate"))))))
            (should-not (plist-get rerun :is-error))
            (should (equal '((:command "x")) harness-perms-test--ran))))
      (harness-remove-filter 'permission/decide gate))))

(provide 'harness-perms-test)
;;; harness-perms-test.el ends here
