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

(provide 'harness-access-test)
;;; harness-access-test.el ends here
