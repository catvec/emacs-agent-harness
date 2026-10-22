;;; harness-access-test.el --- Tests for a session's access: profile, escalation, judgements  -*- lexical-binding: t; -*-

;;; Commentary:

;; The access module (harness-access.el) with the real session store,
;; the permission chain and the demo provider.  The tests define tools
;; of their own: test_fetch, of kind net, and a bash that runs nothing,
;; whose sandbox `sandbox/confined-p' (stubbed) says can or cannot
;; confine it.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-tools)
(defvar harness-provider-demo--delay)
(defvar harness-provider-demo-script-override)
(defvar harness-perms--waiting)
(defvar harness-access--judged)
(defvar harness-permission-mode)
(defvar harness-perms--session-rules)
(defvar harness-sandbox--backend)
(defvar harness-sandbox--programs)
(defvar harness-sandbox--available)
(defvar harness-sandbox-policy)
(declare-function harness-access-profile "harness-access")
(declare-function harness-access-judgements "harness-access")

(defconst harness-access-test-modules
  '(store project config provider provider-demo tools session agent tools-agent tools-fs perms readonly access)
  "The modules every test loads.")

(defvar harness-access-test--confined nil
  "What the stubbed `sandbox/confined-p' answers.")

(defun harness-access-test--define-tools ()
  "Define the tools the tests call besides the modules' own."
  (harness-define-tool "test_fetch" :label "Test fetch" :kind 'net
                       :description "Fetch nothing." :handler (lambda (_input _ctx) (harness-tool-ok "fetched")))
  (harness-define-tool "bash" :label "Bash" :kind 'exec
                       :description "Run nothing." :handler (lambda (_input _ctx) (harness-tool-ok "ran")))
  (harness-define-tool "test_note" :label "Test note" :kind 'meta
                       :description "Note nothing." :handler (lambda (_input _ctx) (harness-tool-ok "noted"))))

(defmacro harness-access-test-with (&rest body)
  "Load the modules and the test's tools, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (when (boundp 'harness-tools) (clrhash harness-tools))
     (dolist (m harness-access-test-modules)
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-access--judged)
     (clrhash harness-perms--waiting)
     (harness-access-test--define-tools)
     (setq harness-access-test--confined nil)
     (harness-register-method 'sandbox/confined-p (lambda (_dir) harness-access-test--confined))
     (let ((harness-provider-demo--delay 0.005)
           (default-directory dir))
       ,@body)))

(defun harness-access-test-session (&rest plist)
  "Create a demo session with PLIST and return its id."
  (plist-get (apply #'harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted"
                    :permission-mode (or (plist-get plist :permission-mode) 'ask)
                    plist)
             :id))

(defun harness-access-test-tools (sid)
  "Return the names of the tools session SID is offered."
  (mapcar (lambda (spec) (plist-get spec :name)) (harness-call 'tools/list sid)))

(defun harness-access-test-run (sid name input &optional call-id)
  "Run tool NAME with INPUT in session SID; return the promise of its result."
  (harness-call 'tools/execute sid (list :id (or call-id (harness-short-id)) :name name :input input)))

(defun harness-access-test-result (sid name input)
  "Run tool NAME with INPUT in session SID and return its result."
  (harness-test-await (harness-access-test-run sid name input)))

(defun harness-access-test-decide (sid tool &optional kind paths input)
  "Return what the permission chain decides for a call of TOOL in SID."
  (harness-test-await
   (harness-tools-decide-traced (list :session (harness-call 'session/get sid) :tool tool
                                      :input input :kind (or kind 'meta) :paths paths
                                      :call-id (harness-short-id)))))

(defun harness-access-test-pending (sid)
  "Wait for a permission request of SID and return it."
  (harness-test-wait (lambda () (car (harness-call 'permission/pending sid))) 5 "a permission request"))

(defun harness-access-test-asks (sid file &optional kind why)
  "Have a call of KIND (write) on FILE in SID ask the user, who says no.
Return the decision's behavior.  The prompt's reason must match WHY,
by default that FILE lies in a directory SID may only read."
  (let* ((kind (or kind 'write))
         (p (harness-tools-decide-traced (list :session (harness-call 'session/get sid)
                                               :tool (if (eq kind 'read) "read_file" "write_file")
                                               :input (list :path file) :kind kind :paths (list file)
                                               :call-id (harness-short-id))))
         (pending (harness-access-test-pending sid)))
    (should (string-match-p (or why "may only read") (plist-get (plist-get pending :payload) :reason)))
    (harness-call 'permission/answer sid (plist-get pending :id) "deny-once")
    (plist-get (harness-test-await p) :behavior)))

(defun harness-access-test-profile (sid)
  "Return the access profile of session SID."
  (harness-access-profile (harness-call 'session/get sid)))

(defun harness-access-test-hints (sid)
  "Return the texts of the hint nodes of session SID, oldest first."
  (delq nil (mapcar (lambda (n) (and (eq (plist-get n :kind) 'hint) (plist-get n :content)))
                    (harness-call 'session/nodes sid))))

(defun harness-access-test-dir-entry (sid dir)
  "Return the entry of `permission/dirs' of SID that is DIR, or nil."
  (cl-find (file-name-as-directory dir) (harness-call 'permission/dirs sid)
           :key (lambda (e) (plist-get e :dir)) :test #'equal))

;;;; Giving access up

(ert-deftest harness-access-drop-network ()
  "Dropping the network takes the net tools away, keeps bash only where the
sandbox runs it offline, refuses a call for good, and runs commands offline."
  (harness-access-test-with
    (let ((sid (harness-access-test-session)))
      (should (member "test_fetch" (harness-access-test-tools sid)))
      (let ((r (harness-access-test-result sid "drop_access" '(:attribute "network" :reason "done with the web"))))
        (should-not (plist-get r :is-error))
        (should (string-match-p "no longer reach the network" (plist-get r :content))))
      (should (eq :false (plist-get (harness-access-test-profile sid) :network)))
      (let ((tools (harness-access-test-tools sid)))
        (should-not (member "test_fetch" tools))
        ;; The sandbox cannot confine bash here, so it would run online.
        (should-not (member "bash" tools))
        (should (member "read_file" tools))
        (should (member "drop_access" tools))
        (should (member "request_escalation" tools)))
      (setq harness-access-test--confined t)
      (should (member "bash" (harness-access-test-tools sid)))
      ;; A call is refused for good, by the access profile, before any mode.
      (harness-call 'session/update sid :permission-mode 'yolo)
      (let ((d (harness-access-test-decide sid "test_fetch" 'net)))
        (should (eq 'deny (plist-get d :behavior)))
        (should (plist-get d :final))
        (should (eq 'access (harness-tools-decision-by d)))
        (should (string-match-p "may not reach the network" (plist-get d :reason)))
        (should (string-match-p "request_escalation" (plist-get d :hint))))
      ;; Commands run offline.
      (should (equal (list :network nil)
                     (harness-run-filter 'tools/sandbox-options nil sid)))
      ;; The transcript says who did it.
      (should (cl-some (lambda (h) (string-match-p "network off (given up by the agent)" h))
                       (harness-access-test-hints sid))))))

(ert-deftest harness-access-drop-access-never-asks ()
  "drop_access is allowed at once in every mode, even with a deny-all rule,
and stays with a read-only session."
  (harness-access-test-with
    (dolist (mode '(ask accept-edits auto yolo))
      (let ((sid (harness-access-test-session :permission-mode mode)))
        (let ((d (harness-access-test-decide sid "drop_access" 'meta nil '(:attribute "network"))))
          (should (eq 'allow (plist-get d :behavior)))
          (should (eq 'access (harness-tools-decision-by d))))))
    (let ((sid (harness-access-test-session)))
      (harness-access-test-result sid "drop_access" '(:attribute "writes"))
      (should (harness-readonly-session-p (harness-call 'session/get sid)))
      (let ((tools (harness-access-test-tools sid)))
        (should (member "drop_access" tools))
        (should (member "request_escalation" tools))
        (should (member "read_file" tools))
        (should-not (member "write_file" tools))
        (should-not (member "test_note" tools)))
      ;; It may still give more up.
      (let ((r (harness-access-test-result sid "drop_access" '(:attribute "network"))))
        (should-not (plist-get r :is-error))))))

(ert-deftest harness-access-drop-a-tool ()
  "A tool turned off is not offered and its calls are refused; drop_access
itself cannot be turned off."
  (harness-access-test-with
    (let ((sid (harness-access-test-session :permission-mode 'yolo)))
      (should-not (plist-get (harness-access-test-result sid "drop_access" '(:attribute "tool" :value "test_note"))
                             :is-error))
      (should (equal '("test_note") (plist-get (harness-access-test-profile sid) :tools-off)))
      (should-not (member "test_note" (harness-access-test-tools sid)))
      (let ((r (harness-access-test-result sid "test_note" nil)))
        (should (plist-get r :is-error))
        (should (string-match-p "turned off for this session" (plist-get r :content))))
      (let ((r (harness-access-test-result sid "drop_access" '(:attribute "tool" :value "drop_access"))))
        (should (plist-get r :is-error))
        (should (string-match-p "cannot be turned off" (plist-get r :content))))
      (let ((r (harness-access-test-result sid "drop_access" '(:attribute "tool" :value "no_such_tool"))))
        (should (plist-get r :is-error))))))

(ert-deftest harness-access-drop-the-working-directory ()
  "Giving the working directory up takes it out of the jail; keep_read
keeps it for reading only, which bash sees read-only."
  (harness-access-test-with
    (let* ((sid (harness-access-test-session :permission-mode 'yolo))
           (cwd (plist-get (harness-call 'session/get sid) :cwd))
           (file (expand-file-name "notes.md" cwd)))
      (should (eq 'allow (plist-get (harness-access-test-decide sid "write_file" 'write (list file)) :behavior)))
      (let ((r (harness-access-test-result sid "drop_access"
                                           (list :attribute "directory" :value cwd :keep_read t))))
        (should-not (plist-get r :is-error))
        (should (string-match-p "may still be read, not written" (plist-get r :content))))
      (let ((e (harness-access-test-dir-entry sid cwd)))
        (should (eq 'read (plist-get e :source)))
        (should (plist-get e :read-only)))
      (should-not (member (file-name-as-directory cwd) (harness-perms-roots (harness-call 'session/get sid))))
      ;; Reading is fine; writing asks the user, even in yolo.
      (should (eq 'allow (plist-get (harness-access-test-decide sid "read_file" 'read (list file)) :behavior)))
      (should (eq 'deny (harness-access-test-asks sid file)))
      ;; Without keep_read it is gone altogether.
      (harness-call 'access/remove-read-dir sid cwd)
      (should-not (harness-access-test-dir-entry sid cwd))
      (should (eq 'deny (harness-access-test-asks sid file 'read "outside the allowed directories")))
      ;; The user gives it back.
      (harness-call 'access/restore-dir sid cwd)
      (should (eq 'cwd (plist-get (harness-access-test-dir-entry sid cwd) :source)))
      (should (eq 'allow (plist-get (harness-access-test-decide sid "write_file" 'write (list file)) :behavior))))))

(ert-deftest harness-access-drop-a-grant-and-what-cannot-be-dropped ()
  "A grant is revoked; the tool output directory and a directory inside a
root stay, with an error that says why."
  (harness-access-test-with
    (let* ((sid (harness-access-test-session))
           (cwd (plist-get (harness-call 'session/get sid) :cwd))
           (extra (file-name-as-directory (file-truename (harness-test-temp-dir)))))
      (harness-call 'permission/allow-dir sid extra)
      (should (eq 'session (plist-get (harness-access-test-dir-entry sid extra) :source)))
      (should-not (plist-get (harness-access-test-result sid "drop_access" (list :attribute "directory" :value extra))
                             :is-error))
      (should-not (harness-access-test-dir-entry sid extra))
      (let ((outputs (cl-find 'outputs (harness-call 'permission/dirs sid) :key (lambda (e) (plist-get e :source)))))
        (should outputs)
        (let ((r (harness-access-test-result sid "drop_access" (list :attribute "directory" :value (plist-get outputs :dir)))))
          (should (plist-get r :is-error))
          (should (string-match-p "cannot be given up" (plist-get r :content)))))
      (make-directory (expand-file-name "sub" cwd) t)
      (let ((r (harness-access-test-result sid "drop_access" (list :attribute "directory" :value (expand-file-name "sub" cwd)))))
        (should (plist-get r :is-error))
        (should (string-match-p "lies inside" (plist-get r :content)))))))

(ert-deftest harness-access-drop-the-mode-and-non-interactive ()
  "A session lowers its own permission mode, never raises it, and turns
non-interactive mode off."
  (harness-access-test-with
    (let ((sid (harness-access-test-session :permission-mode 'auto :non-interactive t)))
      (let ((r (harness-access-test-result sid "drop_access" '(:attribute "permission_mode" :value "yolo"))))
        (should (plist-get r :is-error))
        (should (string-match-p "request_escalation" (plist-get r :content))))
      (should (eq 'auto (plist-get (harness-call 'session/get sid) :permission-mode)))
      (should-not (plist-get (harness-access-test-result sid "drop_access" '(:attribute "permission_mode" :value "accept-edits"))
                             :is-error))
      (should (eq 'accept-edits (plist-get (harness-call 'session/get sid) :permission-mode)))
      (should-not (plist-get (harness-access-test-result sid "drop_access" '(:attribute "non_interactive")) :is-error))
      (should-not (harness-perms--non-interactive-p (harness-call 'session/get sid))))))

;;;; Escalation

(ert-deftest harness-access-escalation-asks-the-user-in-every-mode ()
  "An escalation waits for the user even in yolo, and their yes grants it."
  (harness-access-test-with
    (let ((sid (harness-access-test-session :permission-mode 'yolo
                                            :ext '(:access (:network :false)))))
      (let* ((p (harness-access-test-run sid "request_escalation" '(:attribute "network" :reason "fetch the docs")))
             (pending (harness-access-test-pending sid))
             (payload (plist-get pending :payload)))
        (should-not (harness-promise-settled-p p))
        (should (equal "request_escalation" (plist-get payload :tool)))
        (should (string-match-p "network" (plist-get payload :title)))
        (should (string-match-p "The agent asks: fetch the docs" (plist-get payload :reason)))
        (harness-call 'permission/answer sid (plist-get pending :id) "allow-once")
        (let ((r (harness-test-await p)))
          (should-not (plist-get r :is-error))
          (should (string-match-p "reach the network again" (plist-get r :content)))))
      (should (harness-access-network-p (harness-call 'session/get sid)))
      (should (member "test_fetch" (harness-access-test-tools sid)))
      (should (cl-some (lambda (h) (string-match-p "network on (set by the user)" h))
                       (harness-access-test-hints sid))))))

(ert-deftest harness-access-escalation-denied-and-without-a-user ()
  "The user's no leaves it as it is; a non-interactive session is refused
at once; asking for what the session has grants nothing."
  (harness-access-test-with
    (let ((sid (harness-access-test-session :ext '(:access (:tools-off ("test_note"))))))
      (let* ((p (harness-access-test-run sid "request_escalation" '(:attribute "tool" :value "test_note" :reason "x")))
             (pending (harness-access-test-pending sid)))
        (harness-call 'permission/answer sid (plist-get pending :id) "deny-once")
        (let ((r (harness-test-await p)))
          (should (plist-get r :is-error))
          (should (plist-get r :denied))))
      (should (member "test_note" (plist-get (harness-access-test-profile sid) :tools-off)))
      ;; Something it has already.
      (let ((r (harness-access-test-result sid "request_escalation" '(:attribute "network" :reason "x"))))
        (should-not (plist-get r :is-error))
        (should (string-match-p "Nothing to grant" (plist-get r :content))))
      (should-not (harness-call 'permission/pending sid)))
    (let ((sid (harness-access-test-session :non-interactive t :ext '(:access (:network :false)))))
      (let ((d (harness-access-test-decide sid "request_escalation" 'meta nil '(:attribute "network" :reason "x"))))
        (should (eq 'deny (plist-get d :behavior)))
        (should (eq 'away (harness-tools-decision-by d)))
        (should (string-match-p "non-interactive" (plist-get d :reason)))))))

(ert-deftest harness-access-escalation-of-the-mode ()
  "A more permissive mode is the user's to give; a less permissive one is
nothing to grant; a mode the policy pins is refused."
  (harness-access-test-with
    (let ((sid (harness-access-test-session :permission-mode 'ask)))
      (let* ((p (harness-access-test-run sid "request_escalation" '(:attribute "permission_mode" :value "auto" :reason "x")))
             (pending (harness-access-test-pending sid)))
        (should (string-match-p "auto mode" (plist-get (plist-get pending :payload) :title)))
        (harness-call 'permission/answer sid (plist-get pending :id) "allow-once")
        (should-not (plist-get (harness-test-await p) :is-error)))
      (should (eq 'auto (plist-get (harness-call 'session/get sid) :permission-mode)))
      (let ((r (harness-access-test-result sid "request_escalation" '(:attribute "permission_mode" :value "ask" :reason "x"))))
        (should (string-match-p "Nothing to grant" (plist-get r :content))))
      (cl-letf (((symbol-function 'harness-policy-pinned-p) (lambda (sym) (eq sym 'harness-permission-mode))))
        (let ((d (harness-access-test-decide sid "request_escalation" 'meta nil
                                             '(:attribute "permission_mode" :value "yolo" :reason "x"))))
          (should (eq 'deny (plist-get d :behavior)))
          (should (string-match-p "policy" (plist-get d :reason))))))))

(ert-deftest harness-access-escalation-of-a-directory ()
  "Asking for a directory is the very prompt request_directory_access
makes, and its answer grants the directory; read_directory grants it for
reading only."
  (harness-access-test-with
    (let* ((sid (harness-access-test-session))
           (outside (file-name-as-directory (file-truename (harness-test-temp-dir))))
           (other (file-name-as-directory (file-truename (harness-test-temp-dir)))))
      (let* ((p (harness-access-test-run sid "request_escalation"
                                         (list :attribute "directory" :value outside :reason "the shared types")))
             (pending (harness-access-test-pending sid))
             (payload (plist-get pending :payload)))
        (should (equal outside (plist-get payload :dir)))
        (should (string-match-p "The agent asks for access: the shared types" (plist-get payload :reason)))
        (harness-call 'permission/answer sid (plist-get pending :id) "allow-session")
        (let ((r (harness-test-await p)))
          (should-not (plist-get r :is-error))
          (should (string-match-p "now an allowed directory of this session" (plist-get r :content)))))
      (should (eq 'session (plist-get (harness-access-test-dir-entry sid outside) :source)))
      ;; Read-only.
      (let* ((p (harness-access-test-run sid "request_escalation"
                                         (list :attribute "read_directory" :value other :reason "look")))
             (pending (harness-access-test-pending sid)))
        (should (string-match-p "read" (plist-get (plist-get pending :payload) :title)))
        (harness-call 'permission/answer sid (plist-get pending :id) "allow-once")
        (let ((r (harness-test-await p)))
          (should-not (plist-get r :is-error))
          (should (string-match-p "may now be read" (plist-get r :content)))))
      (let ((e (harness-access-test-dir-entry sid other)))
        (should (plist-get e :read-only)))
      (let ((file (expand-file-name "x" other)))
        (should (eq 'allow (plist-get (harness-access-test-decide sid "read_file" 'read (list file)) :behavior)))
        (harness-call 'session/update sid :permission-mode 'yolo)
        (should (eq 'deny (harness-access-test-asks sid file))))
      ;; A read grant inside a root is nothing to grant.
      (let ((r (harness-access-test-result sid "request_escalation"
                                           (list :attribute "read_directory" :value outside :reason "x"))))
        (should (string-match-p "already readable and writable" (plist-get r :content)))))))

(ert-deftest harness-access-escalation-approved-after-a-denial ()
  "An escalation the user approves after it was denied grants it when the
agent reruns it."
  (harness-access-test-with
    (let ((sid (harness-access-test-session :ext '(:access (:network :false)))))
      (let* ((call-id "esc-1")
             (p (harness-access-test-run sid "request_escalation" '(:attribute "network" :reason "x") call-id))
             (pending (harness-access-test-pending sid)))
        (harness-call 'permission/answer sid (plist-get pending :id) "deny-once")
        (should (plist-get (harness-test-await p) :denied))
        (harness-call 'permission/approve-denied sid call-id)
        (let ((r (harness-access-test-result sid "rerun_approved" (list :handle call-id))))
          (should-not (plist-get r :is-error))
          (should (string-match-p "network again" (plist-get r :content)))))
      (should (harness-access-network-p (harness-call 'session/get sid))))))

(ert-deftest harness-access-settings-files-need-the-user ()
  "Writing a .dir-locals.el asks the user even in yolo; reading it does not."
  (harness-access-test-with
    (let* ((sid (harness-access-test-session :permission-mode 'yolo))
           (cwd (plist-get (harness-call 'session/get sid) :cwd))
           (file (expand-file-name ".dir-locals.el" cwd)))
      (should (eq 'allow (plist-get (harness-access-test-decide sid "read_file" 'read (list file)) :behavior)))
      (let ((p (harness-access-test-run sid "write_file" (list :path file :content "()"))))
        (let ((pending (harness-access-test-pending sid)))
          (should (string-match-p "settings file" (plist-get (plist-get pending :payload) :title)))
          (harness-call 'permission/answer sid (plist-get pending :id) "deny-once"))
        (should (plist-get (harness-test-await p) :denied)))
      (should-not (file-exists-p file))
      ;; A command that writes it.
      (should (harness-access--settings-target
               (list :tool "bash" :kind 'exec :input '(:command "echo '()' > .dir-locals.el"))))
      (should-not (harness-access--settings-target
                   (list :tool "bash" :kind 'exec :input '(:command "cat .dir-locals.el")))))))

;;;; Sub-agents

(ert-deftest harness-access-children-keep-the-restrictions ()
  "A sub-agent takes its parent's restrictions; a fork its read-only
directories too; a BTW nothing."
  (harness-access-test-with
    (let* ((ro (file-name-as-directory (file-truename (harness-test-temp-dir))))
           (parent (harness-access-test-session
                    :ext (list :access (list :network :false :tools-off '("test_note") :read-dirs (list ro)))))
           (child (harness-access-test-session :parent-id parent :kind 'subagent))
           (fork (harness-access-test-session :parent-id parent :kind 'fork :fork-node "n1"))
           (btw (harness-access-test-session :parent-id parent :kind 'btw)))
      (let ((p (harness-access-test-profile child)))
        (should (eq :false (plist-get p :network)))
        (should (equal '("test_note") (plist-get p :tools-off)))
        (should-not (plist-get p :read-dirs)))
      (should (equal (list ro) (plist-get (harness-access-test-profile fork) :read-dirs)))
      (should-not (harness-access-test-profile btw)))))

;;;; Judgements

(ert-deftest harness-access-judgements-of-a-turn ()
  "Each call of a turn is judged, the judgement rides its result node, and
the listing filters by behavior, by who decided and by tool."
  (harness-access-test-with
    (let* ((sid (harness-access-test-session :permission-mode 'ask))
           (cwd (plist-get (harness-call 'session/get sid) :cwd))
           (harness-provider-demo-script-override
            `((:type tool-call :id "j1" :name "drop_access" :input (:attribute "network"))
              (:type tool-call :id "j2" :name "test_fetch" :input (:url "https://example.com"))
              (:type tool-call :id "j3" :name "list_dir" :input (:path ,cwd))
              (:type text :delta "Done.")
              (:type done :stop-reason end-turn))))
      (harness-test-await (harness-call 'agent/prompt sid "go") 20)
      (harness-test-wait (lambda () (eq 'idle (plist-get (harness-call 'session/get sid) :status))) 10 "idle")
      (let* ((all (harness-call 'access/judgements sid))
             (items (plist-get all :items))
             (by-id (lambda (id) (cl-find id items :key (lambda (i) (plist-get i :call-id)) :test #'equal))))
        (should (= 3 (plist-get all :total)))
        (should (eq 'allow (plist-get (funcall by-id "j1") :behavior)))
        (should (eq 'access (plist-get (funcall by-id "j1") :by)))
        (should (eq 'deny (plist-get (funcall by-id "j2") :behavior)))
        (should (eq 'access (plist-get (funcall by-id "j2") :by)))
        (should (string-match-p "network" (plist-get (funcall by-id "j2") :reason)))
        (should (eq 'allow (plist-get (funcall by-id "j3") :behavior)))
        (should (eq 'mode (plist-get (funcall by-id "j3") :by)))
        ;; Newest first, each with its nodes.
        (should (equal '("j3" "j2" "j1") (mapcar (lambda (i) (plist-get i :call-id)) items)))
        (should (equal "test_fetch" (plist-get (plist-get (funcall by-id "j2") :call) :tool)))
        (should (plist-get (funcall by-id "j2") :result))
        (should (equal '(:allow 2 :deny 1 :ask 0) (plist-get all :counts))))
      (should (equal '("j2") (mapcar (lambda (i) (plist-get i :call-id))
                                     (plist-get (harness-call 'access/judgements sid :behavior 'deny) :items))))
      (should (equal '("j3") (mapcar (lambda (i) (plist-get i :call-id))
                                     (plist-get (harness-call 'access/judgements sid :by 'mode) :items))))
      (should (equal '("j1") (mapcar (lambda (i) (plist-get i :call-id))
                                     (plist-get (harness-call 'access/judgements sid :tool "drop_access") :items))))
      (should (equal '("j2") (mapcar (lambda (i) (plist-get i :call-id))
                                     (plist-get (harness-call 'access/judgements sid :query "MAY NOT REACH") :items))))
      ;; The judgement is in the transcript, so it outlives the run.
      (clrhash harness-access--judged)
      (let ((items (plist-get (harness-call 'access/judgements sid) :items)))
        (should (eq 'access (plist-get (car (last items)) :by)))
        (should (eq 'mode (plist-get (car items) :by)))))))

(ert-deftest harness-access-judgements-list-a-waiting-call ()
  "A call waiting for the user is listed as asked, and the answer judges it."
  (harness-access-test-with
    (let* ((sid (harness-access-test-session :permission-mode 'ask))
           (harness-provider-demo-script-override
            '((:type tool-call :id "w1" :name "test_note" :input (:text "hi"))
              (:type done :stop-reason end-turn)))
           (turn (harness-call 'agent/prompt sid "go")))
      (let ((pending (harness-access-test-pending sid)))
        (let ((item (car (plist-get (harness-call 'access/judgements sid) :items))))
          (should (equal "w1" (plist-get item :call-id)))
          (should (eq 'ask (plist-get item :behavior)))
          (should (equal (plist-get pending :id) (plist-get item :pending-id))))
        (should (equal '("w1") (mapcar (lambda (i) (plist-get i :call-id))
                                       (plist-get (harness-call 'access/judgements sid :behavior 'asked) :items))))
        (harness-call 'permission/answer sid (plist-get pending :id) "allow-once"))
      (harness-test-await turn 20)
      (let ((item (car (plist-get (harness-call 'access/judgements sid) :items))))
        (should (eq 'allow (plist-get item :behavior)))
        (should (eq 'user (plist-get item :by)))))))

;;;; Directories on another host

;; The login's home directory on a host is a place of its own, written
;; /ssh:HOST:~/: only the host knows where it is, and nothing here asks it.
;; Abbreviating its name for a message, as Emacs does, would.

(declare-function harness-access--abbrev "harness-access")

(ert-deftest harness-access-abbreviates-a-name-without-asking-its-host ()
  "A message names a directory as Emacs abbreviates it, except that a name on
another host is left as it is: abbreviating one in the home directory of a
login connects to the host."
  (harness-access-test-with
    (harness-test-without-connections
      (dolist (dir '("/ssh:box.example.invalid:~/" "/ssh:box.example.invalid:~/notes/" "/ssh:box.example.invalid:/srv/"))
        (should (equal dir (harness-access--abbrev dir))))
      (should (equal "" (harness-access--abbrev nil)))
      (should (equal (abbreviate-file-name (expand-file-name "~/x/")) (harness-access--abbrev (expand-file-name "~/x/")))))))

(ert-deftest harness-access-directories-on-a-host-need-no-connection ()
  "A directory on another host is one of the session's like any other, the
home directory of a login there included: granting it, describing it,
giving it up, asking for another in it to read or to write, and taking
it away asks no connection."
  (harness-access-test-with
    (let* ((sid (harness-access-test-session))
           (home "/ssh:box.example.invalid:~/")
           (notes "/ssh:box.example.invalid:~/notes/")
           (work "/ssh:box.example.invalid:~/projects/x/"))
      (harness-test-without-connections
        ;; A grant, listed with the session's own directories.
        (harness-call 'permission/allow-dir sid home)
        (should (eq 'session (plist-get (harness-access-test-dir-entry sid home) :source)))
        (should (cl-find home (plist-get (harness-call 'access/describe sid) :dirs)
                         :key (lambda (e) (plist-get e :dir)) :test #'equal))
        ;; The agent gives it up, and the message names it as it is.
        (let ((r (harness-access-test-result sid "drop_access" (list :attribute "directory" :value home))))
          (should-not (plist-get r :is-error))
          (should (string-prefix-p (concat home " is no longer granted to this session.") (plist-get r :content))))
        (should-not (harness-access-test-dir-entry sid home))
        ;; Asking to read a directory in the home: the prompt, the grant and the call it allows.
        (let* ((p (harness-access-test-run sid "request_escalation"
                                           (list :attribute "read_directory" :value notes :reason "look")))
               (pending (harness-access-test-pending sid)))
          (should (equal (concat "Let the agent read " notes) (plist-get (plist-get pending :payload) :title)))
          (harness-call 'permission/answer sid (plist-get pending :id) "allow-once")
          (let ((r (harness-test-await p)))
            (should-not (plist-get r :is-error))
            (should (string-prefix-p (concat notes " may now be read by this session") (plist-get r :content)))))
        (let ((e (harness-access-test-dir-entry sid notes)))
          (should (plist-get e :read-only))
          (should (eq 'read (plist-get e :source))))
        (let ((file (concat notes "todo.org")))
          (should (eq 'allow (plist-get (harness-access-test-decide sid "read_file" 'read (list file)) :behavior)))
          ;; Writing there is not what it may do.
          (should (eq 'deny (harness-access-test-asks sid file))))
        ;; The user takes the read grant away.
        (should (harness-call 'access/remove-read-dir sid notes))
        (should-not (harness-access-test-dir-entry sid notes))
        ;; Asking to write in the home directory: the very prompt request_directory_access makes.
        (let* ((p (harness-access-test-run sid "request_escalation"
                                           (list :attribute "directory" :value work :reason "the shared types")))
               (pending (harness-access-test-pending sid))
               (payload (plist-get pending :payload)))
          (should (equal work (plist-get payload :dir)))
          (should (equal (concat work "**") (plist-get payload :pattern)))
          (should (string-match-p "The agent asks for access: the shared types" (plist-get payload :reason)))
          (harness-call 'permission/answer sid (plist-get pending :id) "allow-session")
          (let ((r (harness-test-await p)))
            (should-not (plist-get r :is-error))
            (should (string-match-p (concat (regexp-quote work) " is now an allowed directory of this session")
                                    (plist-get r :content)))))
        (should (eq 'session (plist-get (harness-access-test-dir-entry sid work) :source)))
        ;; The user revokes it.
        (harness-call 'permission/revoke-dir sid work)
        (should-not (harness-access-test-dir-entry sid work))
        (should-error (harness-call 'access/remove-read-dir sid notes))
        (should (cl-some (lambda (h) (string-match-p (regexp-quote notes) h)) (harness-access-test-hints sid)))))))

;;;; Describing a session's access

(ert-deftest harness-access-describe ()
  "access/describe gathers the sandbox, mode, directories, tools and rules."
  (harness-access-test-with
    (harness-register-method 'sandbox/status (lambda () '(:backend bwrap :available (bwrap) :policy auto)))
    ;; A tool of other kinds of session, as hand_in is a task's.
    (harness-define-tool "test_hand_in" :label "Test hand in" :kind 'meta
                         :description "Hand nothing in." :handler (lambda (_input _ctx) (harness-tool-ok "handed in")))
    (harness-add-filter 'agent/tools (lambda (names _session) (remove "test_hand_in" names)) 50)
    (let* ((sid (harness-access-test-session :permission-mode 'accept-edits
                                             :ext '(:access (:network :false :tools-off ("test_note")))))
           (d (harness-call 'access/describe sid))
           (entry (lambda (name off) (cl-find name off :key (lambda (e) (plist-get e :name)) :test #'equal))))
      (should (eq 'bwrap (plist-get (plist-get d :sandbox) :backend)))
      (should (eq 'accept-edits (plist-get d :mode)))
      (should-not (plist-get d :network))
      (should (cl-find 'cwd (plist-get d :dirs) :key (lambda (e) (plist-get e :source))))
      (let ((off (plist-get (plist-get d :tools) :off)))
        (should (equal "turned off" (plist-get (funcall entry "test_note" off) :why)))
        (should (plist-get (funcall entry "test_note" off) :profile))
        (should (equal "no network" (plist-get (funcall entry "test_fetch" off) :why)))
        (should-not (plist-get (funcall entry "test_fetch" off) :elsewhere))
        ;; Nobody turned it off: it is for other kinds of session.
        (should (plist-get (funcall entry "test_hand_in" off) :elsewhere))
        (should-not (plist-get (funcall entry "test_hand_in" off) :profile)))
      (should (member "read_file" (plist-get (plist-get d :tools) :on))))))

(ert-deftest harness-access-user-setters ()
  "The access/* setters change the profile for the user and say so."
  (harness-access-test-with
    (let ((sid (harness-access-test-session)))
      (harness-call 'access/set-network sid :false)
      (harness-call 'access/set-read-only sid t)
      (harness-call 'access/set-tool sid "test_note" :false)
      (should (equal '(:network :false :read-only t :tools-off ("test_note"))
                     (harness-access-test-profile sid)))
      (harness-call 'access/set-network sid t)
      (harness-call 'access/set-read-only sid :false)
      (harness-call 'access/set-tool sid "test_note" t)
      (should-not (harness-access-test-profile sid))
      (should (cl-some (lambda (h) (string-match-p "(set by the user)" h)) (harness-access-test-hints sid))))))

;;;; Linux capabilities

;; The sandbox module is loaded for these, so that a capability's name
;; means what it does there; what it answers about the jail
;; (`sandbox/capabilities') is the test's to say, so the tests do not
;; depend on the machine they run on.  The last one uses the real jail.

(defvar harness-access-test--jail nil
  "What the stubbed `sandbox/capabilities' answers: a plist, as the jail's.")

(defconst harness-access-test--jail-enforcing
  '(:enforced t :backend bwrap
    :grantable ("CAP_SYS_PTRACE" "CAP_NET_RAW" "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE")
    :docs (("CAP_SYS_PTRACE" . "trace and inspect any process in the sandbox (strace, gdb)")
           ("CAP_NET_RAW" . "open raw and packet sockets")
           ("CAP_NET_ADMIN" . "configure the network")
           ("CAP_NET_BIND_SERVICE" . "bind sockets to the ports below 1024"))
    :scopes (("CAP_SYS_PTRACE" . "It reaches the processes of the sandbox's own PID namespace.")
             ("CAP_NET_RAW" . "Only effective when the session has no network.")
             ("CAP_NET_ADMIN" . "Only effective when the session has no network.")
             ("CAP_NET_BIND_SERVICE" . "Only effective when the session has no network."))
    :why nil)
  "The jail of a bwrap sandbox an ordinary user runs.")

(defun harness-access-test--jail (&rest changes)
  "Return the enforcing jail with CHANGES, a plist, put over it."
  (let ((jail (copy-sequence harness-access-test--jail-enforcing)))
    (cl-loop for (key value) on changes by #'cddr do (setq jail (plist-put jail key value)))
    jail))

(defmacro harness-access-test-with-jail (&rest body)
  "Run BODY as `harness-access-test-with' does, with the sandbox module loaded.
`sandbox/capabilities' answers `harness-access-test--jail', by default
`harness-access-test--jail-enforcing'."
  (declare (indent 0))
  `(harness-access-test-with
     (harness-test-load-module 'sandbox)
     (setq harness-access-test--jail harness-access-test--jail-enforcing)
     (harness-register-method 'sandbox/capabilities (lambda (_cwd) harness-access-test--jail))
     (harness-register-method 'sandbox/confined-p (lambda (_dir) harness-access-test--confined))
     ,@body))

(defun harness-access-test-caps (sid)
  "Return the capabilities SID's commands are given."
  (harness-access-capabilities (harness-call 'session/get sid)))

(defun harness-access-test-ask-capability (sid value &optional answer)
  "Ask for the capability VALUE in session SID; have the user ANSWER (allow-once).
Return the tool's result."
  (let* ((p (harness-access-test-run sid "request_escalation"
                                     (list :attribute "capability" :value value :reason "see where it is stuck")))
         (pending (harness-access-test-pending sid)))
    (harness-call 'permission/answer sid (plist-get pending :id) (or answer "allow-once"))
    (harness-test-await p)))

(ert-deftest harness-access-capability-escalation-asks-the-user-in-every-mode ()
  "Asking for a capability puts a prompt to the user in every mode, yolo
included, with what it is and where it counts; the user's yes gives the
session's commands that capability, from the next command on."
  (harness-access-test-with-jail
    (dolist (mode '(ask accept-edits auto yolo))
      (let ((sid (harness-access-test-session :permission-mode mode)))
        (let* ((p (harness-access-test-run sid "request_escalation"
                                           '(:attribute "capability" :value "ptrace"
                                             :reason "see where the thread is stuck")))
               (pending (harness-access-test-pending sid))
               (payload (plist-get pending :payload))
               (reason (plist-get payload :reason)))
          (should-not (harness-promise-settled-p p))
          (should (equal "request_escalation" (plist-get payload :tool)))
          (should (equal "Give the agent's commands CAP_SYS_PTRACE" (plist-get payload :title)))
          (should (string-match-p "CAP_SYS_PTRACE lets a command trace and inspect any process" reason))
          (should (string-match-p "bwrap sandbox, which drops every capability" reason))
          (should (string-match-p "inside the sandbox's own namespaces only, not on the host and not on another machine" reason))
          (should (string-match-p "PID namespace" reason))
          (should (string-match-p "from the next bash or elisp command on, until the agent or you take it away" reason))
          (should (string-match-p "The agent asks: see where the thread is stuck" reason))
          ;; Nothing is granted while the user has not answered.
          (should-not (harness-access-test-caps sid))
          (harness-call 'permission/answer sid (plist-get pending :id) "allow-once")
          (let* ((r (harness-test-await p))
                 (text (plist-get r :content)))
            (should-not (plist-get r :is-error))
            (should (string-match-p "gave this session's commands CAP_SYS_PTRACE" text))
            (should (string-match-p "next bash or elisp command on they run with CAP_SYS_PTRACE and with no other capability" text))
            (should (string-match-p "commands already running keep what they started with" text))
            (should (string-match-p "not on the host and not on another machine" text))
            (should (string-match-p "drop_access" text))))
        (should (equal '("CAP_SYS_PTRACE") (harness-access-test-caps sid)))
        (should (equal '(:capabilities ("CAP_SYS_PTRACE")) (harness-run-filter 'tools/sandbox-options nil sid)))
        (should (cl-some (lambda (h) (string-match-p "CAP_SYS_PTRACE given to the session's commands (set by the user)" h))
                         (harness-access-test-hints sid)))))
    ;; A second one joins the first.
    (let ((sid (harness-access-test-session :permission-mode 'yolo)))
      (harness-access-test-ask-capability sid "CAP_SYS_PTRACE")
      (let ((r (harness-access-test-ask-capability sid "net_raw")))
        (should (string-match-p "run with CAP_SYS_PTRACE, CAP_NET_RAW and with no other" (plist-get r :content)))
        (should (string-match-p "Only effective when the session has no network" (plist-get r :content))))
      (should (equal '("CAP_SYS_PTRACE" "CAP_NET_RAW") (harness-access-test-caps sid)))
      (should (equal '(:capabilities ("CAP_SYS_PTRACE" "CAP_NET_RAW"))
                     (harness-run-filter 'tools/sandbox-options nil sid))))))

(ert-deftest harness-access-capability-escalation-denied-and-without-a-user ()
  "The user's no gives the session's commands nothing; a non-interactive
session, whose user is away, is refused at once, and nobody is asked."
  (harness-access-test-with-jail
    (let ((sid (harness-access-test-session :permission-mode 'yolo)))
      (let ((r (harness-access-test-ask-capability sid "CAP_SYS_PTRACE" "deny-once")))
        (should (plist-get r :is-error))
        (should (plist-get r :denied)))
      (should-not (harness-access-test-caps sid))
      (should-not (harness-access-test-profile sid))
      (should-not (harness-run-filter 'tools/sandbox-options nil sid)))
    (let ((sid (harness-access-test-session :non-interactive t :permission-mode 'yolo)))
      (let ((d (harness-access-test-decide sid "request_escalation" 'meta nil
                                           '(:attribute "capability" :value "CAP_SYS_PTRACE" :reason "x"))))
        (should (eq 'deny (plist-get d :behavior)))
        (should (eq 'away (harness-tools-decision-by d)))
        (should (string-match-p "non-interactive" (plist-get d :reason))))
      (should-not (harness-call 'permission/pending sid))
      (should-not (harness-access-test-caps sid)))))

(ert-deftest harness-access-capability-escalation-refusals ()
  "A request that cannot be granted is refused at once, with a hint, before
anyone is asked: no value, no such capability, one the user does not let
agents ask for, a jail that cannot enforce it, a read-only session."
  (harness-access-test-with-jail
    (cl-flet ((refuses (sid input reason hint)
                (let ((d (harness-access-test-decide sid "request_escalation" 'meta nil
                                                     (append (list :attribute "capability" :reason "x") input))))
                  (should (eq 'deny (plist-get d :behavior)))
                  (should (plist-get d :final))
                  (should (eq 'access (harness-tools-decision-by d)))
                  (should (string-match-p reason (plist-get d :reason)))
                  (should (string-match-p hint (plist-get d :hint)))
                  (should-not (harness-call 'permission/pending sid))
                  (should-not (harness-access-test-caps sid)))))
      (let ((sid (harness-access-test-session :permission-mode 'yolo)))
        ;; No value, or a name that is none.
        (refuses sid nil "capability needs value: the capability's name, one of CAP_SYS_PTRACE, CAP_NET_RAW"
                 "value set to the capability")
        (dolist (junk '("CAP_BOGUS" "ALL" "all" "CAP_SYS_PTRACE --bind / /"))
          (refuses sid (list :value junk) (format "no capability is named %s" (regexp-quote junk))
                   "The user lets agents ask for: CAP_SYS_PTRACE, CAP_NET_RAW, CAP_NET_ADMIN, CAP_NET_BIND_SERVICE"))
        ;; A capability the registry knows and the user does not let agents ask for.
        (refuses sid '(:value "sys_admin") "CAP_SYS_ADMIN is not one the user lets an agent ask for"
                 "The user lets agents ask for: CAP_SYS_PTRACE")
        (setq harness-access-test--jail (harness-access-test--jail :grantable '("CAP_NET_RAW")))
        (refuses sid '(:value "ptrace") "CAP_SYS_PTRACE is not one the user lets an agent ask for"
                 "The user lets agents ask for: CAP_NET_RAW\\.")
        (setq harness-access-test--jail (harness-access-test--jail :grantable nil))
        (refuses sid '(:value "ptrace") "CAP_SYS_PTRACE is not one the user lets an agent ask for"
                 "no capability (harness-sandbox-grantable-capabilities is empty)")
        ;; A jail that does not enforce capabilities.
        (dolist (why '("the sandbox backend is systemd-run, not bwrap, and a systemd --user unit cannot be given a capability"
                       "no sandbox backend can confine its commands"
                       "its commands run on another host, where the sandbox does not reach"
                       "/usr/bin/bwrap is setuid root, where --cap-add would hand out real capabilities"
                       "the sandbox policy is `off'"))
          (setq harness-access-test--jail (harness-access-test--jail :enforced nil :why why))
          (refuses sid '(:value "CAP_SYS_PTRACE")
                   (concat "the sandbox cannot give this session's commands a capability: " (regexp-quote why))
                   "changes nothing for a command the sandbox does not run here")))
      ;; A read-only session: by its own profile it asks for writing first.
      (setq harness-access-test--jail harness-access-test--jail-enforcing)
      (let ((sid (harness-access-test-session :permission-mode 'yolo :ext '(:access (:read-only t)))))
        (refuses sid '(:value "CAP_SYS_PTRACE")
                 "this session is read-only, and a read-only session's commands get no capability"
                 "request_escalation (attribute writes)"))
      ;; By another module's policy nothing the user can grant changes it.
      (harness-readonly-register 'test-reader
                                 (lambda (s) (and (equal (plist-get s :name) "reader")
                                                  (list :label "test reader" :doing "only reads"))))
      (let ((sid (harness-access-test-session :permission-mode 'yolo :name "reader")))
        (refuses sid '(:value "CAP_SYS_PTRACE")
                 "read-only by test reader, which no escalation changes"
                 "Carry on reading")))))

(ert-deftest harness-access-capability-escalation-without-the-sandbox-module ()
  "Without the sandbox module nothing confines the commands, so no capability
is given: a request is refused, saying so."
  (harness-access-test-with
    (let* ((sid (harness-access-test-session :permission-mode 'yolo))
           (d (harness-access-test-decide sid "request_escalation" 'meta nil
                                          '(:attribute "capability" :value "CAP_SYS_PTRACE" :reason "x"))))
      (should-not (harness-method-exists-p 'sandbox/capabilities))
      (should (eq 'deny (plist-get d :behavior)))
      (should (string-match-p "sandbox module is not loaded" (plist-get d :reason)))
      (should-not (harness-call 'permission/pending sid))
      (should (plist-get (plist-get (harness-access-describe sid) :capabilities) :why))
      (should-not (plist-get (plist-get (harness-access-describe sid) :capabilities) :enforced)))))

(ert-deftest harness-access-capability-already-held-grants-nothing ()
  "Asking for what the session's commands have is nothing to grant, however
it is spelled, and asks nobody."
  (harness-access-test-with-jail
    (let ((sid (harness-access-test-session :permission-mode 'ask
                                            :ext '(:access (:caps ("CAP_SYS_PTRACE"))))))
      (dolist (spelling '("CAP_SYS_PTRACE" "ptrace" "cap-sys-ptrace"))
        (let ((r (harness-access-test-result sid "request_escalation"
                                             (list :attribute "capability" :value spelling :reason "x"))))
          (should-not (plist-get r :is-error))
          (should (string-match-p "Nothing to grant: this session's commands have CAP_SYS_PTRACE already"
                                  (plist-get r :content)))))
      (should-not (harness-call 'permission/pending sid))
      (should (equal '(:caps ("CAP_SYS_PTRACE")) (harness-access-test-profile sid)))
      (should-not (harness-access-test-hints sid)))))

(ert-deftest harness-access-capability-escalation-approved-after-a-denial ()
  "A request the user approves after it was denied gives the capability when
the agent reruns it; one the jail or the user's list would not allow is still
refused then, whoever approved it."
  (harness-access-test-with-jail
    (let ((sid (harness-access-test-session)))
      (let* ((call-id "cap-1")
             (p (harness-access-test-run sid "request_escalation"
                                         '(:attribute "capability" :value "CAP_SYS_PTRACE" :reason "x") call-id))
             (pending (harness-access-test-pending sid)))
        (harness-call 'permission/answer sid (plist-get pending :id) "deny-once")
        (should (plist-get (harness-test-await p) :denied))
        (harness-call 'permission/approve-denied sid call-id)
        (let ((r (harness-access-test-result sid "rerun_approved" (list :handle call-id))))
          (should-not (plist-get r :is-error))
          (should (string-match-p "gave this session's commands CAP_SYS_PTRACE" (plist-get r :content)))))
      (should (equal '("CAP_SYS_PTRACE") (harness-access-test-caps sid))))
    ;; Refused at once, and approved: the grant still checks the list.
    (let ((sid (harness-access-test-session))
          (call-id "cap-2"))
      (let ((r (harness-test-await
                (harness-access-test-run sid "request_escalation"
                                         '(:attribute "capability" :value "CAP_SYS_ADMIN" :reason "x") call-id))))
        (should (plist-get r :is-error))
        (should (plist-get r :denied)))
      (harness-call 'permission/approve-denied sid call-id)
      (let ((r (harness-access-test-result sid "rerun_approved" (list :handle call-id))))
        (should (plist-get r :is-error))
        (should (string-match-p "CAP_SYS_ADMIN is not one the user lets an agent ask for" (plist-get r :content))))
      (should-not (harness-access-test-caps sid))
      (should-not (harness-access-test-profile sid)))))

(ert-deftest harness-access-drop-a-capability ()
  "drop_access takes one capability or all of them away at once, in any
spelling, and says what is left; it needs no answer from anyone."
  (harness-access-test-with-jail
    (let ((sid (harness-access-test-session
                :ext '(:access (:caps ("CAP_SYS_PTRACE" "CAP_NET_RAW" "CAP_NET_ADMIN"))))))
      (let* ((r (harness-access-test-result sid "drop_access"
                                            '(:attribute "capability" :value "ptrace" :reason "done tracing")))
             (text (plist-get r :content)))
        (should-not (plist-get r :is-error))
        (should (string-match-p "CAP_SYS_PTRACE taken away from this session's commands" text))
        (should (string-match-p "run without it, still with CAP_NET_RAW, CAP_NET_ADMIN" text))
        (should (string-match-p "commands already running keep what they started with" text))
        (should (string-match-p "request_escalation" text)))
      (should (equal '("CAP_NET_RAW" "CAP_NET_ADMIN") (harness-access-test-caps sid)))
      (should (equal '(:capabilities ("CAP_NET_RAW" "CAP_NET_ADMIN"))
                     (harness-run-filter 'tools/sandbox-options nil sid)))
      ;; What it does not hold is nothing to give up.
      (let ((r (harness-access-test-result sid "drop_access" '(:attribute "capability" :value "CAP_SYS_PTRACE"))))
        (should-not (plist-get r :is-error))
        (should (string-match-p "hold CAP_NET_RAW, CAP_NET_ADMIN, not CAP_SYS_PTRACE: there is nothing to give up"
                                (plist-get r :content))))
      ;; A value is needed.
      (should (plist-get (harness-access-test-result sid "drop_access" '(:attribute "capability")) :is-error))
      ;; All of them.
      (let ((r (harness-access-test-result sid "drop_access" '(:attribute "capability" :value "all"))))
        (should-not (plist-get r :is-error))
        (should (string-match-p "CAP_NET_RAW, CAP_NET_ADMIN taken away from this session's commands" (plist-get r :content)))
        (should (string-match-p "run without them" (plist-get r :content))))
      (should-not (harness-access-test-caps sid))
      (should-not (harness-access-test-profile sid))
      (should-not (harness-run-filter 'tools/sandbox-options nil sid))
      (let ((hints (harness-access-test-hints sid)))
        (should (cl-some (lambda (h) (string-match-p "CAP_SYS_PTRACE taken away from the session's commands (given up by the agent)" h)) hints))
        (should (cl-some (lambda (h) (string-match-p "no capability left for the session's commands (given up by the agent)" h)) hints)))
      (should-not (harness-call 'permission/pending sid)))))

(ert-deftest harness-access-drop-a-capability-asks-nobody ()
  "Giving a capability up needs no answer in any mode, in a read-only session,
with a rule that denies every call, and whatever the jail can enforce."
  (harness-access-test-with-jail
    (dolist (jail (list harness-access-test--jail-enforcing
                        (harness-access-test--jail :enforced nil :why "the sandbox backend is systemd-run")))
      (setq harness-access-test--jail jail)
      (dolist (mode '(ask accept-edits auto yolo))
        (let ((sid (harness-access-test-session :permission-mode mode
                                                :ext '(:access (:read-only t :caps ("CAP_SYS_PTRACE" "CAP_NET_RAW"))))))
          (puthash sid (list (list :behavior 'deny)) harness-perms--session-rules)
          (let ((d (harness-access-test-decide sid "drop_access" 'meta nil '(:attribute "capability" :value "all"))))
            (should (eq 'allow (plist-get d :behavior)))
            (should (eq 'access (harness-tools-decision-by d))))
          (should (harness-readonly-session-p (harness-call 'session/get sid)))
          (should (member "drop_access" (harness-access-test-tools sid)))
          (let ((r (harness-access-test-result sid "drop_access" '(:attribute "capability" :value "CAP_NET_RAW"))))
            (should-not (plist-get r :is-error)))
          (should (equal '("CAP_SYS_PTRACE") (harness-access-test-caps sid)))
          (should-not (harness-call 'permission/pending sid))
          (should-not (plist-get (harness-access-test-result sid "drop_access" '(:attribute "capability" :value "all"))
                                 :is-error))
          (should-not (harness-access-test-caps sid))
          (should-not (harness-call 'permission/pending sid)))))))

(ert-deftest harness-access-capabilities-are-a-grant-in-the-profile ()
  "The capabilities are a grant, not a restriction: a profile of them alone
is a profile, stored only when there are any, once each, and the stages that
return early for a session without a profile leave its tools as they are."
  (harness-access-test-with-jail
    (should-not (harness-access--normalise nil))
    (should-not (harness-access--normalise '(:caps nil)))
    (should-not (harness-access--normalise (list :caps (list 1 :a))))
    (should (equal '(:caps ("CAP_SYS_PTRACE" "CAP_NET_RAW"))
                   (harness-access--normalise '(:caps ("CAP_SYS_PTRACE" "CAP_NET_RAW" "CAP_SYS_PTRACE")))))
    (should (equal '(:network :false :read-only t :tools-off ("a") :read-dirs ("/x/") :dropped ("/y/") :caps ("CAP_NET_RAW"))
                   (harness-access--normalise '(:caps ("CAP_NET_RAW") :dropped ("/y/") :read-dirs ("/x/")
                                                :tools-off ("a") :read-only t :network :false))))
    (let* ((plain (harness-access-test-session :permission-mode 'yolo))
           (sid (harness-access-test-session :permission-mode 'yolo :ext '(:access (:caps ("CAP_SYS_PTRACE")))))
           (session (harness-call 'session/get sid)))
      (should (equal '(:caps ("CAP_SYS_PTRACE")) (harness-access-profile session)))
      (should (equal '("CAP_SYS_PTRACE") (harness-access-capabilities session)))
      (should-not (harness-access-capabilities (harness-call 'session/get plain)))
      (should (harness-access-network-p session))
      (should-not (harness-access-read-only-p session))
      ;; The same tools as a session without a profile, and the same decisions.
      (should (equal (harness-access-test-tools plain) (harness-access-test-tools sid)))
      (dolist (tool '("test_fetch" "bash" "test_note" "drop_access"))
        (let ((d (harness-access--profile-refusal (list :session session :tool tool))))
          (should (eq (and (equal tool "drop_access") t) (and d t)))))
      (should (eq 'mode (harness-tools-decision-by (harness-access-test-decide sid "test_fetch" 'net))))
      (should (eq 'allow (plist-get (harness-access-test-decide sid "test_fetch" 'net) :behavior)))
      ;; Kept with the session through a restart.
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should (equal '("CAP_SYS_PTRACE") (harness-access-capabilities (harness-call 'session/get sid)))))))

(ert-deftest harness-access-sandbox-options-carry-the-capabilities ()
  "The sandbox options of a session's commands name its capabilities, only
when it has some, and a read-only session's commands get none, whoever
made them read-only."
  (harness-access-test-with-jail
    (let ((none (harness-access-test-session))
          (some (harness-access-test-session :ext '(:access (:caps ("CAP_SYS_PTRACE" "CAP_NET_RAW")))))
          (offline (harness-access-test-session :ext '(:access (:network :false :caps ("CAP_NET_RAW")))))
          (own (harness-access-test-session :ext '(:access (:read-only t :caps ("CAP_SYS_PTRACE")))))
          (other (harness-access-test-session :name "reader" :ext '(:access (:caps ("CAP_SYS_PTRACE"))))))
      (harness-readonly-register 'test-reader
                                 (lambda (s) (and (equal (plist-get s :name) "reader") (list :label "test reader"))))
      ;; No empty key: a remote command refuses to run unconfined when it has options.
      (should (equal nil (harness-run-filter 'tools/sandbox-options nil none)))
      (should (equal '(:capabilities ("CAP_SYS_PTRACE" "CAP_NET_RAW")) (harness-run-filter 'tools/sandbox-options nil some)))
      (should (equal '(:network nil :capabilities ("CAP_NET_RAW")) (harness-run-filter 'tools/sandbox-options nil offline)))
      ;; Read-only commands look and touch nothing, whatever filter put the capabilities there.
      (should (equal '(:read-only t :network nil) (harness-run-filter 'tools/sandbox-options nil own)))
      (should (equal '(:read-only t :network nil) (harness-run-filter 'tools/sandbox-options nil other)))
      (let ((options (harness-readonly--sandbox-options '(:capabilities ("CAP_SYS_PTRACE") :network t) other)))
        (should-not (plist-member options :capabilities))
        (should (eq t (plist-get options :read-only)))
        (should (plist-member options :network))
        (should-not (plist-get options :network)))
      (let ((options (harness-readonly--sandbox-options '(:writable ("/x/") :capabilities ("CAP_SYS_PTRACE")) other)))
        (should-not (plist-member options :capabilities))
        (should (equal '("/x/") (plist-get options :writable)))
        (should (eq t (plist-get options :read-only))))
      ;; Still held: they come back with writing.
      (should (equal '("CAP_SYS_PTRACE") (harness-access-test-caps own))))
    ;; An error choosing them leaves the commands offline and without any.
    (cl-letf (((symbol-function 'harness-access-capabilities) (lambda (_session) (error "Broken"))))
      (let ((sid (harness-access-test-session :ext '(:access (:caps ("CAP_SYS_PTRACE"))))))
        (should (equal '(:network nil)
                       (harness-access--sandbox-options '(:capabilities ("CAP_NET_RAW")) sid)))))))

(ert-deftest harness-access-forks-inherit-capabilities-sub-agents-do-not ()
  "A fork takes the capabilities its parent gave its commands, as it takes its
directory grants; a sub-agent that starts afresh and a BTW have to ask, and
take only the restrictions."
  (harness-access-test-with-jail
    (let* ((parent (harness-access-test-session
                    :ext '(:access (:network :false :caps ("CAP_SYS_PTRACE" "CAP_NET_RAW")))))
           (fork (harness-access-test-session :parent-id parent :kind 'fork :fork-node "n1"))
           (forked-subagent (harness-access-test-session :parent-id parent :kind 'subagent :fork-node "n1"))
           (subagent (harness-access-test-session :parent-id parent :kind 'subagent))
           (btw (harness-access-test-session :parent-id parent :kind 'btw)))
      (should (equal '(:network :false :caps ("CAP_SYS_PTRACE" "CAP_NET_RAW")) (harness-access-test-profile fork)))
      (should (equal '(:network :false :caps ("CAP_SYS_PTRACE" "CAP_NET_RAW")) (harness-access-test-profile forked-subagent)))
      (should (cl-some (lambda (h) (string-match-p "capabilities it gave its commands" h)) (harness-access-test-hints fork)))
      (should (equal '(:network :false) (harness-access-test-profile subagent)))
      (should-not (harness-access-test-profile btw))
      (should (equal '(:network nil :capabilities ("CAP_SYS_PTRACE" "CAP_NET_RAW"))
                     (harness-run-filter 'tools/sandbox-options nil fork)))
      (should (equal '(:network nil) (harness-run-filter 'tools/sandbox-options nil subagent)))
      ;; What the fork holds is its own from then on.
      (harness-access-revoke-capability fork "all" 'agent)
      (should (equal '("CAP_SYS_PTRACE" "CAP_NET_RAW") (harness-access-test-caps parent)))
      (should-not (harness-access-test-caps fork)))
    ;; A parent with capabilities and nothing else: the sub-agent has no profile at all.
    (let* ((parent (harness-access-test-session :ext '(:access (:caps ("CAP_SYS_PTRACE")))))
           (subagent (harness-access-test-session :parent-id parent :kind 'subagent))
           (fork (harness-access-test-session :parent-id parent :kind 'fork :fork-node "n1")))
      (should-not (harness-access-test-profile subagent))
      (should (equal '(:caps ("CAP_SYS_PTRACE")) (harness-access-test-profile fork))))))

(ert-deftest harness-access-describe-capabilities ()
  "access/describe says what the session's commands hold, what may be asked
for and what each is, whether the jail enforces it, and why one cannot be
raised now."
  (harness-access-test-with-jail
    (let* ((sid (harness-access-test-session :ext '(:access (:caps ("CAP_NET_RAW")))))
           (c (plist-get (harness-call 'access/describe sid) :capabilities)))
      (should (equal '("CAP_NET_RAW") (plist-get c :held)))
      (should (equal '("CAP_SYS_PTRACE" "CAP_NET_RAW" "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE") (plist-get c :grantable)))
      (should (eq t (plist-get c :enforced)))
      (should (eq 'bwrap (plist-get c :backend)))
      (should-not (plist-get c :why))
      (let ((doc (cl-find "CAP_SYS_PTRACE" (plist-get c :docs) :key (lambda (d) (plist-get d :name)) :test #'equal)))
        (should (string-match-p "strace" (plist-get doc :doc)))
        (should (string-match-p "PID namespace" (plist-get doc :scope))))
      ;; What crosses to the view as JSON.
      (should (stringp (harness-json-encode (harness-call 'access/describe sid)))))
    ;; Raising one is not possible in a read-only session, nor where the jail cannot, nor when nothing is grantable.
    (let ((sid (harness-access-test-session :ext '(:access (:read-only t :caps ("CAP_NET_RAW"))))))
      (let ((c (plist-get (harness-call 'access/describe sid) :capabilities)))
        (should (equal '("CAP_NET_RAW") (plist-get c :held)))
        (should (eq t (plist-get c :enforced)))
        (should (string-match-p "read-only" (plist-get c :why)))))
    (harness-readonly-register 'test-reader
                               (lambda (s) (and (equal (plist-get s :name) "reader") (list :label "test reader"))))
    (let ((c (plist-get (harness-call 'access/describe (harness-access-test-session :name "reader")) :capabilities)))
      (should (string-match-p "read-only by test reader" (plist-get c :why))))
    (setq harness-access-test--jail (harness-access-test--jail :enforced nil :why "the sandbox backend is systemd-run"))
    (let ((c (plist-get (harness-call 'access/describe (harness-access-test-session)) :capabilities)))
      (should-not (plist-get c :enforced))
      (should (equal "the sandbox backend is systemd-run" (plist-get c :why))))
    (setq harness-access-test--jail (harness-access-test--jail :grantable nil :docs nil))
    (let ((c (plist-get (harness-call 'access/describe (harness-access-test-session)) :capabilities)))
      (should (plist-get c :enforced))
      (should-not (plist-get c :grantable))
      (should (string-match-p "no capability" (plist-get c :why))))))

(ert-deftest harness-access-user-sets-capabilities ()
  "access/set-capability gives a session's commands a capability, or takes one
or all away, for the user and asking nobody, as access/set-tool does; it
refuses to give one the jail would not pass on."
  (harness-access-test-with-jail
    (dolist (mode '(ask yolo))
      (let ((sid (harness-access-test-session :permission-mode mode)))
        (should (eq t (harness-call 'access/set-capability sid "ptrace" t)))
        (should (eq t (harness-call 'access/set-capability sid "CAP_NET_RAW" t)))
        (should (equal '("CAP_SYS_PTRACE" "CAP_NET_RAW") (harness-access-test-caps sid)))
        (should (eq t (harness-call 'access/set-capability sid "CAP_SYS_PTRACE" :false)))
        (should (equal '("CAP_NET_RAW") (harness-access-test-caps sid)))
        ;; Not held, or no capability: nothing to take away, nothing changes.
        (should (eq t (harness-call 'access/set-capability sid "CAP_NET_ADMIN" :false)))
        (should (eq t (harness-call 'access/set-capability sid "bogus" :false)))
        (should (equal '("CAP_NET_RAW") (harness-access-test-caps sid)))
        (should (eq t (harness-call 'access/set-capability sid "all" :false)))
        (should-not (harness-access-test-profile sid))
        (should-not (harness-call 'permission/pending sid))
        (should (cl-some (lambda (h) (string-match-p "CAP_SYS_PTRACE given to the session's commands (set by the user)" h))
                         (harness-access-test-hints sid)))
        (should (cl-some (lambda (h) (string-match-p "no capability left for the session's commands (set by the user)" h))
                         (harness-access-test-hints sid)))))
    ;; The user's own sessions may be non-interactive: the change is theirs.
    (let ((sid (harness-access-test-session :non-interactive t)))
      (harness-call 'access/set-capability sid "ptrace" t)
      (should (equal '("CAP_SYS_PTRACE") (harness-access-test-caps sid))))
    ;; What the jail would not pass on is not recorded as given.
    (let ((sid (harness-access-test-session)))
      (should-error (harness-call 'access/set-capability sid "CAP_BOGUS" t) :type 'harness-error)
      (should-error (harness-call 'access/set-capability sid "sys_admin" t) :type 'harness-error)
      (should-error (harness-call 'access/set-capability sid "all" t) :type 'harness-error)
      (setq harness-access-test--jail (harness-access-test--jail :enforced nil :why "the sandbox backend is systemd-run"))
      (let ((err (should-error (harness-call 'access/set-capability sid "ptrace" t) :type 'harness-error)))
        (should (string-match-p "systemd-run" (harness-error-message err))))
      (setq harness-access-test--jail harness-access-test--jail-enforcing)
      (harness-call 'access/set-read-only sid t)
      (let ((err (should-error (harness-call 'access/set-capability sid "ptrace" t) :type 'harness-error)))
        (should (string-match-p "read-only" (harness-error-message err))))
      (should-not (harness-access-test-caps sid)))))

;;;; The rule over every attribute

;; What a session may reach is raised only by the user and lowered by
;; the agent at once.  Each attribute is listed here with a session that
;; lacks it and the request that would give it back, so that an
;; attribute added to `harness-access-attributes' later cannot be
;; raised, or lowered, any other way without a test saying so.

(defun harness-access-test--attribute-case (attribute mode &rest session-options)
  "Return (SID . INPUT): a session in MODE lacking ATTRIBUTE, and the request raising it.
SESSION-OPTIONS are more options for the session."
  (let* ((outside (file-name-as-directory (file-truename (harness-test-temp-dir))))
         (spec (pcase attribute
                 ("directory" (list nil (list :attribute attribute :value outside)))
                 ("read_directory" (list nil (list :attribute attribute :value outside)))
                 ("writes" (list '(:access (:read-only t)) (list :attribute attribute)))
                 ("network" (list '(:access (:network :false)) (list :attribute attribute)))
                 ("tool" (list '(:access (:tools-off ("test_note"))) (list :attribute attribute :value "test_note")))
                 ("permission_mode" (list nil (list :attribute attribute :value "yolo")))
                 ("non_interactive" (list nil (list :attribute attribute)))
                 ("capability" (list nil (list :attribute attribute :value "CAP_SYS_PTRACE")))
                 (_ (ert-fail (list "Add a case for the attribute" attribute "to the rule's test")))))
         (sid (apply #'harness-access-test-session :permission-mode mode
                     (append (and (car spec) (list :ext (car spec))) session-options))))
    (cons sid (append (cadr spec) (list :reason "the task needs it")))))

(defun harness-access-test--raise (sid input)
  "Decide a call of request_escalation with INPUT in session SID.
Return `asked' when the user was asked and said no, `nothing' when it
asked for what the session has, `refused' when it was refused at once.
Fail the test when anything else lets it through."
  (let ((p (harness-tools-decide-traced
            (list :session (harness-call 'session/get sid) :tool "request_escalation"
                  :input input :kind 'meta :call-id (harness-short-id)))))
    (if (harness-promise-settled-p p)
        (let ((d (harness-test-await p)))
          (cond ((eq 'deny (plist-get d :behavior)) 'refused)
                ((stringp (plist-get (plist-get d :input) :nothing)) 'nothing)
                (t (ert-fail (list "An escalation was allowed without the user" input d)))))
      (let ((pending (harness-access-test-pending sid)))
        (should (equal "request_escalation" (plist-get (plist-get pending :payload) :tool)))
        (harness-call 'permission/answer sid (plist-get pending :id) "deny-once")
        (let ((d (harness-test-await p)))
          (should (eq 'deny (plist-get d :behavior)))
          'asked)))))

(ert-deftest harness-access-every-attribute-is-raised-only-by-the-user ()
  "For every attribute, request_escalation never lets a request through
without the user, in any mode, with a rule that allows every call, or for a
session whose user is away; it asks, or grants nothing."
  (harness-access-test-with-jail
    (let ((asked nil))
      (dolist (attribute harness-access-attributes)
        (dolist (mode harness-access-modes)
          (dolist (rule '(nil allow-all))
            (let* ((case (harness-access-test--attribute-case attribute mode))
                   (sid (car case))
                   (dirs (harness-call 'permission/allowed-dirs sid))
                   (profile (harness-access-test-profile sid)))
              (when rule
                (puthash sid (list (list :behavior 'allow)) harness-perms--session-rules))
              (let ((outcome (harness-access-test--raise sid (cdr case))))
                (should (memq outcome '(asked nothing refused)))
                (when (eq outcome 'asked) (cl-pushnew attribute asked :test #'equal))
                ;; Whatever came of it, nothing was granted.
                (let ((session (harness-call 'session/get sid)))
                  (should (equal profile (harness-access-test-profile sid)))
                  (should (equal dirs (harness-call 'permission/allowed-dirs sid)))
                  (should (eq mode (plist-get session :permission-mode)))
                  (should-not (harness-perms--non-interactive-p session)))))))
        ;; A user who is away cannot be asked: refused at once, or nothing to grant.
        (let* ((case (harness-access-test--attribute-case attribute 'yolo :non-interactive t))
               (outcome (harness-access-test--raise (car case) (cdr case))))
          (should (memq outcome '(refused nothing)))))
      ;; The cases are not vacuous: each attribute was asked about somewhere.
      (should (equal (sort (copy-sequence harness-access-attributes) #'string<) (sort asked #'string<))))))

(ert-deftest harness-access-every-attribute-is-lowered-at-once ()
  "For every attribute but read_directory, which is given up as a directory,
drop_access is allowed at once in every mode, in a read-only session and
against a rule that denies every call, and its call asks nobody."
  (harness-access-test-with-jail
    (dolist (attribute (remove "read_directory" harness-access-attributes))
      (dolist (mode harness-access-modes)
        (let* ((cwd nil)
               (sid (pcase attribute
                      ("permission_mode" (harness-access-test-session :permission-mode 'yolo))
                      (_ (harness-access-test-session :permission-mode mode
                                                      :non-interactive (equal attribute "non_interactive")
                                                      :ext (and (equal attribute "capability")
                                                                '(:access (:caps ("CAP_SYS_PTRACE")))))))))
          (setq cwd (plist-get (harness-call 'session/get sid) :cwd))
          (puthash sid (list (list :behavior 'deny)) harness-perms--session-rules)
          (let* ((input (pcase attribute
                          ("directory" (list :attribute attribute :value cwd))
                          ("tool" (list :attribute attribute :value "test_note"))
                          ("permission_mode" (list :attribute attribute :value "ask"))
                          ("capability" (list :attribute attribute :value "all"))
                          (_ (list :attribute attribute))))
                 (d (harness-access-test-decide sid "drop_access" 'meta nil input)))
            (should (eq 'allow (plist-get d :behavior)))
            (should (eq 'access (harness-tools-decision-by d)))
            (should-not (harness-call 'permission/pending sid))
            ;; The call itself works, asks nobody, and takes the access away.
            (let ((r (harness-access-test-result sid "drop_access" input)))
              (should-not (plist-get r :is-error))
              (should-not (harness-call 'permission/pending sid)))))))
    ;; Even a session that is read-only already, and one the jail cannot enforce anything for.
    (setq harness-access-test--jail (harness-access-test--jail :enforced nil :why "no bwrap"))
    (let ((sid (harness-access-test-session :ext '(:access (:read-only t :network :false :caps ("CAP_SYS_PTRACE"))))))
      (dolist (input '((:attribute "capability" :value "all") (:attribute "network") (:attribute "writes")))
        (should-not (plist-get (harness-access-test-result sid "drop_access" input) :is-error)))
      (should-not (harness-call 'permission/pending sid)))))

(ert-deftest harness-access-attributes-are-the-ones-the-tools-offer ()
  "The tools name the attributes there are: the escalation tool all of
them, the tool that gives access up all but read_directory."
  (harness-access-test-with-jail
    (should (member "capability" harness-access-attributes))
    (let ((escalate (plist-get (harness-tool-schema (harness-tool-get "request_escalation")) :properties))
          (drop (plist-get (harness-tool-schema (harness-tool-get "drop_access")) :properties)))
      (should (equal harness-access-attributes (append (plist-get (plist-get escalate :attribute) :enum) nil)))
      (should (equal (remove "read_directory" harness-access-attributes)
                     (append (plist-get (plist-get drop :attribute) :enum) nil)))
      (should (string-match-p "CAP_SYS_PTRACE" (plist-get (plist-get escalate :value) :description)))
      (should (string-match-p "Linux capability" (harness-tool-description (harness-tool-get "request_escalation"))))
      (should (string-match-p "Linux capability" (harness-tool-description (harness-tool-get "drop_access")))))
    (let ((r (harness-access-test-result (harness-access-test-session) "request_escalation" '(:reason "x"))))
      (should (plist-get r :is-error)))
    (let ((d (harness-access-test-decide (harness-access-test-session) "request_escalation" 'meta nil '(:reason "x"))))
      (should (string-match-p "directory, read_directory, writes, network, tool, permission_mode, non_interactive, capability"
                              (plist-get d :reason))))
    (let ((r (harness-access-test-result (harness-access-test-session) "drop_access" '(:reason "x"))))
      (should (string-match-p "directory, writes, network, tool, permission_mode, non_interactive, capability"
                              (plist-get r :content))))))

;;;; With the real jail

(ert-deftest harness-access-capabilities-reach-the-real-sandbox ()
  "A capability the user gave a session's commands is passed to the sandbox
as `--cap-add', through the options the sandbox is asked for, and not to a
read-only session's commands; given up, it is not passed any more."
  (harness-access-test-with
    (harness-test-load-module 'sandbox)
    (let ((harness-sandbox--backend 'bwrap)
          (harness-sandbox--programs '((bwrap . "/usr/bin/bwrap")))
          (harness-sandbox--available '(bwrap))
          (harness-sandbox-policy 'preferred))
      (cl-letf (((symbol-function 'harness-sandbox--setuid-p) (lambda (_program) nil))
                ((symbol-function 'harness-sandbox--root-p) (lambda () nil)))
        (let* ((sid (harness-access-test-session :permission-mode 'yolo))
               (cwd (plist-get (harness-call 'session/get sid) :cwd))
               (adds (lambda ()
                       (let ((cmd (apply #'harness-call 'sandbox/wrap cwd '("true")
                                         (harness-run-filter 'tools/sandbox-options nil sid))))
                         (cl-loop for (arg next) on (seq-take-while (lambda (a) (not (equal a "--"))) cmd)
                                  when (equal arg "--cap-add") collect next)))))
          (should (plist-get (plist-get (harness-call 'access/describe sid) :capabilities) :enforced))
          (should-not (funcall adds))
          (let ((r (harness-access-test-ask-capability sid "ptrace")))
            (should-not (plist-get r :is-error)))
          (should (equal '("CAP_SYS_PTRACE") (funcall adds)))
          ;; The user has not let agents ask for this one: it is refused, and passes nothing.
          (let ((d (harness-access-test-decide sid "request_escalation" 'meta nil
                                               '(:attribute "capability" :value "CAP_SYS_ADMIN" :reason "x"))))
            (should (eq 'deny (plist-get d :behavior)))
            (should (string-match-p "not one the user lets an agent ask for" (plist-get d :reason))))
          (should (equal '("CAP_SYS_PTRACE") (funcall adds)))
          ;; Read-only, it is given none, and gets it back with writing.
          (harness-access-set-read-only sid t 'agent)
          (should-not (funcall adds))
          (should (equal '("CAP_SYS_PTRACE") (harness-access-test-caps sid)))
          (harness-access-set-read-only sid nil 'user)
          (should (equal '("CAP_SYS_PTRACE") (funcall adds)))
          ;; Given up, it is gone.
          (harness-access-test-result sid "drop_access" '(:attribute "capability" :value "CAP_SYS_PTRACE"))
          (should-not (funcall adds))
          (should-not (harness-access-test-profile sid)))))))

(provide 'harness-access-test)
;;; harness-access-test.el ends here
