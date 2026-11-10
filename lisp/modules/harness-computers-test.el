;;; harness-computers-test.el --- Tests for computers: registry, access, the gate  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness.

;;; Commentary:

;; The computers module (harness-computers.el) with the real session
;; store and the permission chain's filter, but no MCP transport: a
;; client is a record of another transport (`harness-acp-add-client'),
;; and its writer counts what the harness sends, so registration and
;; attachment are tried without a socket.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)

(defvar harness-acp--calling-client nil)
;; Bound before the acp module loads, so its defvar keeps this and no test
;; starts a TCP server.
(defvar harness-acp--server-enabled nil)
(defvar harness-computers--computers)
(defvar harness-computers--client-info)
(defvar harness-computers--client-binding)
(defvar harness-computers--loaded)
(declare-function harness-acp-add-client "harness-acp" (&rest args))
(declare-function harness-computers-access "harness-computers" (session-id))
(declare-function harness-computers-get "harness-computers" (id-or-name))
(declare-function harness-computers--entry "harness-computers" (access id))
(declare-function harness-computers--control-holder "harness-computers" (record))
(declare-function harness-computers--gate "harness-computers" (decision next request))
(declare-function harness-computers--id "harness-computers" (value))
(declare-function harness-computers-grant "harness-computers" (session-id computer &optional capabilities window who))
(declare-function harness-computers-revoke "harness-computers" (session-id computer &optional capability who))

(defconst harness-computers-test-modules
  '(store project config provider provider-demo tools session agent tools-agent perms readonly mcp acp
    computers tools-computers)
  "The modules every test loads, in the order they load.")

(defun harness-computers-test--reset ()
  "Forget every computer this Emacs's earlier test made."
  (clrhash harness-computers--computers)
  (clrhash harness-computers--client-info)
  (clrhash harness-computers--client-binding)
  (setq harness-computers--loaded nil)
  ;; What the module's init does: read the store, so a later
  ;; registration is not read over by a first load.
  (harness-computers--load))

(defmacro harness-computers-test-with (&rest body)
  "Load the modules and a fresh registry, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (when (boundp 'harness-tools) (clrhash harness-tools))
     (let ((harness-acp--server-enabled nil))
       (dolist (m harness-computers-test-modules)
         (harness-test-load-module m))
       (clrhash harness-sessions)
       (harness-computers-test--reset)
       (let ((default-directory (harness-test-temp-dir)))
         ,@body))))

(defun harness-computers-test-client (&optional remote)
  "Return a client of a test transport, on another computer when REMOTE."
  (harness-acp-add-client 'test :writer #'ignore :remote remote))

(defun harness-computers-test-id (name)
  "Return the id a computer NAMEs registers with."
  (harness-computers--id name))

(defun harness-computers-test-session (&rest plist)
  "Create a demo session with PLIST and return its id."
  (plist-get (apply #'harness-call 'session/create :cwd (harness-test-temp-dir)
                    :model "demo:scripted"
                    :permission-mode (or (plist-get plist :permission-mode) 'ask)
                    plist)
             :id))

(defconst harness-computers-test-secret
  "a-registration-secret-of-at-least-32-characters"
  "The secret a test client registers its computer with.")

(defun harness-computers-test-register (client &optional id name resources)
  "Register ID (NAME) for CLIENT, a client on another computer; return the record."
  (let ((harness-acp--calling-client client))
    (plist-get (harness-call 'computer/register
                             :computer (list :id (or id "box") :name (or name id "box")
                                             :host "box.example.test"
                                             :capabilities '("view" "pointer"))
                             :secret harness-computers-test-secret
                             :resources resources
                             :servers (list (list :name "computer" :title "Computer")))
               :computer)))

(defun harness-computers-test-remote-record (name &rest props)
  "Put a connected record of a computer NAMEs into the registry; return it.
PROPS go into the record: `:resources', `:capabilities', `:state', `:kind'."
  (let* ((id (or (plist-get props :id) (harness-computers-test-id name)))
         (base (list :id id :name name :kind 'client :state 'connected
                    :capabilities '("view" "windows" "pointer" "keyboard" "clipboard")
                    :servers (list (list :name "computer" :title "Computer"))))
         (record nil))
    (dolist (key '(:id :name :kind :state :capabilities :servers :resources))
      (when (plist-member props key)
        (setq base (harness-plist-remove base key))))
    (setq record (append base props))
    (puthash id record harness-computers--computers)
    record))

(defun harness-computers-test-decision (session request)
  "Run the computer gate over REQUEST for SESSION and return its decision.
The gate is the permission chain's stage at 7; the chain's earlier
stages are the perms module's, tried by its own suite."
  (harness-computers--gate
   (list :behavior 'allow :by 'mode)
   #'identity
   (append (list :session session :tool "test_tool" :input nil
                 :kind 'meta :call-id (harness-short-id))
           request)))

(defun harness-computers-test-subscribe ()
  "Return a cell collecting every `computers/changed' event."
  (let ((events (list nil)))
    (harness-on 'computers/changed
                (lambda (id what) (push (list id what) (car events))))
    events))

;;;; No computer of its own

(ert-deftest harness-computers-none-is-registered-at-start ()
  "The harness server has no computer of its own.
Only a client's registration makes one, and until then the list is
empty and no session may use a machine."
  (harness-computers-test-with
    (should-not (harness-call 'computer/list))
    (should-not (harness-call 'computer/resources))
    (let* ((sid (harness-computers-test-session))
           (access (harness-computers-access sid)))
      (should (eq 'auto (plist-get access :policy)))
      (should-not (plist-get access :computers))
      (should-not (plist-get access :available)))))

;;;; Registration and authentication

(ert-deftest harness-computers-a-store-from-before-has-no-local-computer ()
  "A registry written while the server had a computer `local' is read
without it: the server has no computer of its own now."
  (harness-computers-test-with
    (puthash "local" (list :id "local" :name "old"
                           :kind 'local :implicit t :state 'connected
                           :capabilities nil :resources nil :servers nil)
             harness-computers--computers)
    (puthash "cmp-box" (list :id "cmp-box" :name "box" :kind 'client
                             :state 'disconnected :capabilities nil
                             :resources nil :servers nil)
             harness-computers--computers)
    (harness-computers--save)
    (setq harness-computers--loaded nil)
    (clrhash harness-computers--computers)
    (harness-computers--load)
    (should-not (harness-computers-get "local"))
    (should (harness-computers-get "cmp-box"))))

(ert-deftest harness-computers-registration-needs-a-client-on-the-computer ()
  "Only a client can register a computer, and it must say which one.
A second registration with another secret is refused: attach to it, or
unregister it first."
  (harness-computers-test-with
    (let ((err (should-error (harness-call 'computer/register
                                           :computer '(:id "box" :name "box")
                                           :secret harness-computers-test-secret)
                             :type 'harness-error)))
      (should (string-match-p "from a client running on it" (harness-error-message err))))
    (let* ((one (harness-computers-test-client '(:address "192.0.2.10")))
           (two (harness-computers-test-client '(:address "192.0.2.11")))
           (record (harness-computers-test-register one)))
      (should (equal (harness-computers-test-id "box") (plist-get record :id)))
      (should (eq 'client (plist-get record :kind)))
      (should (plist-get record :connected))
      (should (harness-computers-get "box"))
      ;; The secret is kept salted, never in the record a page reads.
      (should (consp (plist-get (harness-computers-get "box") :secret)))
      (should-not (plist-get record :secret))
      ;; Another client cannot take the registration over with a secret of its own.
      (let ((harness-acp--calling-client two))
        (let ((err (should-error
                    (harness-call 'computer/register
                                  :computer '(:id "box" :name "box" :host "box.example.test")
                                  :secret "another-secret-of-at-least-32-characters"
                                  :servers (list (list :name "computer")))
                    :type 'harness-error)))
          (should (string-match-p "registered already" (harness-error-message err)))))
      ;; A registration with the same secret replaces the record and hands a new token.
      (let* ((harness-acp--calling-client one)
             (again (harness-call 'computer/register
                                  :computer '(:id "box" :name "box" :host "box.example.test")
                                  :secret harness-computers-test-secret
                                  :servers (list (list :name "computer" :title "Computer")))))
        (should (stringp (plist-get again :token)))))))

(ert-deftest harness-computers-registration-keeps-the-screen-endpoints ()
  "A computer's VNC page and its RFB socket are kept, and read back.
The page is for a person; the socket is what a client draws."
  (harness-computers-test-with
    (let* ((client (harness-computers-test-client '(:address "192.0.2.10")))
           (harness-acp--calling-client client)
           (record (plist-get
                    (harness-call 'computer/register
                                  :computer (list :id "box" :name "box"
                                                  :host "box.example.test"
                                                  :vnc "http://127.0.0.1:6080/vnc_lite.html"
                                                  :vnc-socket "ws://127.0.0.1:6080/websockify"
                                                  :capabilities '("view" "pointer" "sandbox"))
                                  :secret harness-computers-test-secret
                                  :servers (list (list :name "computer")))
                    :computer)))
      (should (equal "http://127.0.0.1:6080/vnc_lite.html"
                     (plist-get record :vnc)))
      (should (equal "ws://127.0.0.1:6080/websockify"
                     (plist-get record :vnc-socket)))
      (should (equal '("view" "pointer" "sandbox")
                     (plist-get record :capability-names)))
      (let ((listed (harness-call 'computer/get "box")))
        (should (equal "ws://127.0.0.1:6080/websockify"
                       (plist-get listed :vnc-socket)))))))

(ert-deftest harness-computers-update-keeps-the-screen-endpoints ()
  "A client reports its display and screen again with `computer/update'.
A restart, a new VNC server or a screen that moved is not a new
registration: the record takes what the client says now."
  (harness-computers-test-with
    (let* ((client (harness-computers-test-client '(:address "192.0.2.10")))
           (box (harness-computers-test-register client "box" "the box"))
           (id (plist-get box :id)))
      (let ((harness-acp--calling-client client))
        (let ((record (harness-call 'computer/update
                                    id
                                    :secret harness-computers-test-secret
                                    :display ":102"
                                    :vnc "http://127.0.0.1:6100/vnc_lite.html"
                                    :vnc-socket "ws://127.0.0.1:6100/websockify"
                                    :window-scoped :false
                                    :capabilities '("view" "windows" "pointer" "keyboard" "sandbox"))))
          (should (equal ":102" (plist-get record :display)))
          (should (equal "http://127.0.0.1:6100/vnc_lite.html" (plist-get record :vnc)))
          (should (equal "ws://127.0.0.1:6100/websockify" (plist-get record :vnc-socket)))
          (should (equal '("view" "windows" "pointer" "keyboard" "sandbox")
                         (plist-get record :capability-names))))))))

(ert-deftest harness-computers-attach-binds-the-client-and-checks-the-secret ()
  "A client attaches to the computer it registered with its secret.
A wrong secret is refused, and a computer in use by one client does not
serve another."
  (harness-computers-test-with
    (let* ((one (harness-computers-test-client '(:address "192.0.2.10")))
           (two (harness-computers-test-client '(:address "192.0.2.11")))
           (_ (harness-computers-test-register one)))
      (let ((harness-acp--calling-client two))
        (let ((err (should-error (harness-call 'computer/attach "box" "not-the-secret-at-all-32-characters")
                                 :type 'harness-error)))
          (should (string-match-p "did not authenticate" (harness-error-message err))))
        (let ((err (should-error (harness-call 'computer/attach "box" harness-computers-test-secret)
                                 :type 'harness-error)))
          (should (string-match-p "serving another client" (harness-error-message err)))))
      (let* ((harness-acp--calling-client one)
             (result (harness-call 'computer/attach "box" harness-computers-test-secret)))
        (should (equal (harness-computers-test-id "box")
                       (plist-get (plist-get result :computer) :id)))
        (should (stringp (plist-get result :token))))
      ;; The client that attached is bound: it may speak for the computer.
      (let ((harness-acp--calling-client one))
        (should (equal (harness-computers-test-id "box")
                       (plist-get (harness-call 'computer/update
                                                "box" :secret harness-computers-test-secret
                                                :capabilities '("view" "audio"))
                                  :id)))
        (should (equal '("view" "audio")
                       (plist-get (harness-computers-get "box") :capabilities)))))))

(ert-deftest harness-computers-unregister-removes-a-computer ()
  "The client that registered a computer can unregister it.
Nothing is left of it, and the list is empty again."
  (harness-computers-test-with
    (let* ((one (harness-computers-test-client '(:address "192.0.2.10")))
           (two (harness-computers-test-client '(:address "192.0.2.11")))
           (events (harness-computers-test-subscribe)))
      (harness-computers-test-register one)
      (let ((harness-acp--calling-client two))
        (let ((err (should-error (harness-call 'computer/unregister "box") :type 'harness-error)))
          (should (string-match-p "does not manage" (harness-error-message err)))))
      (let ((harness-acp--calling-client one))
        (should (harness-call 'computer/unregister "box")))
      (should-not (harness-computers-get "box"))
      (should-not (harness-call 'computer/list))
      (should (equal (list (harness-computers-test-id "box") 'removed)
                     (car (car events)))))))

;;;; What a session may use

(ert-deftest harness-computers-session-defaults-are-least-privilege ()
  "A session may use no computer by default; a workspace every one.
The client's computer and a resource's computer come with the session,
and the policy none leaves even those out."
  (harness-computers-test-with
    (let* ((box (harness-computers-test-remote-record "box"))
           (box-id (plist-get box :id))
           (sid (harness-computers-test-session))
           (access (harness-computers-access sid)))
      (should (eq 'auto (plist-get access :policy)))
      (should-not (plist-get (harness-computers--entry access box-id) :allowed)))
    (let* ((workspace (harness-computers-test-session :kind 'workspace))
           (access (harness-computers-access workspace))
           (ids (mapcar (lambda (c) (plist-get c :id)) (plist-get access :computers))))
      (should (eq 'all (plist-get access :policy)))
      (should (equal (list (harness-computers-test-id "box")) ids))
      (should (cl-every (lambda (c) (plist-get c :allowed)) (plist-get access :computers))))
    (let ((harness-computers-access 'none))
      (let* ((sid (harness-computers-test-session))
             (access (harness-computers-access sid)))
        (should (eq 'none (plist-get access :policy)))
        (should-not (plist-get (harness-computers--entry access (harness-computers-test-id "box"))
                               :allowed))))))

(ert-deftest harness-computers-a-resource-of-the-session-lets-its-computer-in ()
  "A session works on a resource of a computer: that computer is allowed."
  (harness-computers-test-with
    (let* ((sid (harness-computers-test-session))
           (dir (directory-file-name (plist-get (harness-call 'session/get sid) :cwd))))
      (harness-computers-test-remote-record
       "buildbox" :resources (list (list :kind "git-repo" :name "project"
                                         :path dir :branch "main")))
      (let* ((access (harness-computers-access sid))
             (entry (harness-computers--entry access (harness-computers-test-id "buildbox"))))
        (should (plist-get entry :allowed))
        (should (equal "a resource of the session" (plist-get entry :why)))
        (should (equal dir (plist-get (car (plist-get (harness-computers-get "buildbox") :resources))
                                      :path)))))))

(ert-deftest harness-computers-the-client-computer-is-recorded-not-pinned ()
  "A session the user makes from a client on a computer may use that
computer, and is not pinned to it: a call that names another still goes there."
  (harness-computers-test-with
    (let* ((client (harness-computers-test-client '(:address "192.0.2.10")))
           (_ (harness-computers-test-register client "box" "the box"))
           (_ (harness-computers--on-initialize
               client
               (list :clientCapabilities
                     (list :_harness
                           (list :computer (list :id "box" :name "the box"
                                                 :host "box.example.test"
                                                 :capabilities '("view")))))))
           (sid (let ((harness-acp--calling-client client))
                  (harness-computers-test-session)))
           (session (harness-call 'session/get sid))
           (access (harness-computers-access sid))
           (box (harness-computers--entry access (harness-computers-test-id "box"))))
      (should (equal "the client's computer" (plist-get box :why)))
      (should (plist-get box :allowed))
      ;; It is a fact about the session, not a pin: the preference is elsewhere.
      (should-not (plist-get access :preferred))
      (should (equal (harness-computers-test-id "box")
                     (plist-get (plist-get session :ext) :client-computer)))
      ;; A session the harness makes itself (a task) records no client computer.
      (let ((plain (harness-computers-test-session)))
        (should-not (plist-get (plist-get (harness-call 'session/get plain) :ext)
                               :client-computer))))))

(ert-deftest harness-computers-a-grant-holds-the-capabilities-it-names ()
  "A grant names the capabilities the session may use; without it, all
the computer offers.  Revoking the last capability gives the computer up."
  (harness-computers-test-with
    (harness-computers-test-remote-record "box")
    (let ((sid (harness-computers-test-session)))
      (harness-computers-grant sid "box" '("view" "pointer") nil 'user)
      (let* ((access (harness-computers-access sid))
             (entry (harness-computers--entry access (harness-computers-test-id "box"))))
        (should (plist-get entry :allowed))
        (should (equal '("view" "pointer") (plist-get entry :capabilities-allowed)))
        (should (equal "a grant of the session" (plist-get entry :why)))
        (should (equal '("view" "pointer")
                     (let ((grant (car (plist-get (plist-get (harness-call 'session/get sid) :ext)
                                                  :computers))))
                       (plist-get grant :capabilities)))))
      ;; Taking one capability away keeps the computer, with the others.
      (harness-call 'computer/grant-capability sid "box" "pointer" nil)
      (should (equal '("view")
                     (plist-get (harness-computers--entry
                                 (harness-computers-access sid)
                                 (harness-computers-test-id "box"))
                                :capabilities-allowed)))
      (harness-call 'computer/grant-capability sid "box" "view" nil)
      (let* ((access (harness-computers-access sid))
             (entry (harness-computers--entry access (harness-computers-test-id "box"))))
        (should-not (plist-get entry :allowed)))
      ;; The revocation is kept, so a default would not let it back in.
      (should (equal (list (harness-computers-test-id "box"))
                     (plist-get (harness-computers-access sid) :revoked))))))

(ert-deftest harness-computers-a-preference-is-not-a-pin ()
  "A session's preferred computer is the one a nameless call uses.
A call that names a computer still goes to the one it names."
  (harness-computers-test-with
    (let* ((box (harness-computers-test-remote-record "box"))
           (other (harness-computers-test-remote-record "other"))
           (sid (harness-computers-test-session)))
      (harness-computers-grant sid "box" nil nil 'user)
      (harness-computers-grant sid "other" nil nil 'user)
      (harness-call 'computer/set-preference sid "box")
      (let ((nameless (harness-call 'computers/check sid))
            (named (harness-call 'computers/check sid :computer "other")))
        (should (equal (plist-get box :id) (plist-get nameless :id)))
        (should (equal (plist-get other :id) (plist-get named :id)))
        (should (equal (plist-get box :id)
                       (plist-get (harness-computers-access sid) :preferred)))))))

;;;; The permission gate

(ert-deftest harness-computers-the-gate-refuses-a-computer-the-session-may-not-use ()
  "A call whose computer the session may not use is denied for good, in
every mode, with the way to ask for it.  A call there is allowed when
the session may use it."
  (harness-computers-test-with
    (let ((sid (harness-computers-test-session :permission-mode 'yolo))
          (session nil))
      (setq session (harness-call 'session/get sid))
      (harness-computers-test-remote-record "box")
      (harness-computers-grant sid "box" nil nil 'user)
      (harness-computers-test-remote-record "other")
      (let ((allowed (harness-computers-test-decision
                      session (list :computer (list :computer "box"))))
            (denied (harness-computers-test-decision
                     session (list :computer (list :computer "other")))))
        (should (eq 'allow (plist-get allowed :behavior)))
        (should (equal (harness-computers-test-id "box") (plist-get allowed :computer)))
        (should (eq 'deny (plist-get denied :behavior)))
        (should (plist-get denied :final))
        (should (eq 'computer (plist-get denied :by)))
        (should (string-match-p "may not use the computer other" (plist-get denied :reason)))
        (should (string-match-p "request_escalation" (plist-get denied :hint))))
      ;; A computer no client runs on is refused with the reason.
      (harness-computers-test-remote-record "offbox" :state 'disconnected)
      (harness-computers-grant sid "offbox" nil nil 'user)
      (let ((denied (harness-computers-test-decision
                     session (list :computer (list :computer "offbox")))))
        (should (eq 'deny (plist-get denied :behavior)))
        (should (string-match-p "not connected" (plist-get denied :reason)))))))

(ert-deftest harness-computers-the-gate-holds-each-capability-to-the-grant ()
  "A capability the computer has not, and one the session's grant leaves
out, are each refused; the grant's own are allowed."
  (harness-computers-test-with
    (let* ((sid (harness-computers-test-session :permission-mode 'yolo))
           (session (harness-call 'session/get sid)))
      (harness-computers-test-remote-record "box"
                                            :capabilities '("view" "pointer"))
      (harness-computers-grant sid "box" '("view") nil 'user)
      (let ((allowed (harness-computers-test-decision
                      session (list :computer (list :computer "box" :capability "view"))))
            (missing (harness-computers-test-decision
                      session (list :computer (list :computer "box" :capability "audio"))))
            (not-in-grant (harness-computers-test-decision
                           session (list :computer (list :computer "box" :capability "pointer")))))
        (should (eq 'allow (plist-get allowed :behavior)))
        (should (eq 'deny (plist-get missing :behavior)))
        (should (string-match-p "no audio capability" (plist-get missing :reason)))
        (should (eq 'deny (plist-get not-in-grant :behavior)))
        (should (string-match-p "may not use pointer" (plist-get not-in-grant :reason)))
        (should (string-match-p "capabilities pointer" (plist-get not-in-grant :hint)))))))

(ert-deftest harness-computers-a-person-with-control-holds-the-input ()
  "While a person has control of a computer the agent may look, not type.
Giving control back lets the agent use it again."
  (harness-computers-test-with
    (let* ((sid (harness-computers-test-session :permission-mode 'yolo))
           (session (harness-call 'session/get sid)))
      (harness-computers-test-remote-record "box"
                                            :capabilities '("view" "keyboard"))
      (harness-computers-grant sid "box" nil nil 'user)
      (harness-call 'computer/take-control "box")
      (should (equal "the user"
                     (harness-computers--control-holder (harness-computers-get "box"))))
      (let ((look (harness-computers-test-decision
                   session (list :computer (list :computer "box" :capability "view"))))
            (type (harness-computers-test-decision
                   session (list :computer (list :computer "box" :capability "keyboard" :input t)))))
        (should (eq 'allow (plist-get look :behavior)))
        (should (eq 'deny (plist-get type :behavior)))
        (should (string-match-p "user has control" (plist-get type :reason))))
      (harness-call 'computer/release-control "box")
      (should-not (harness-computers--control-holder (harness-computers-get "box")))
      (let ((type (harness-computers-test-decision
                   session (list :computer (list :computer "box" :capability "keyboard" :input t)))))
        (should (eq 'allow (plist-get type :behavior)))))))

(ert-deftest harness-computers-a-call-without-a-computer-is-not-gated ()
  "A tool that runs on no computer passes the gate untouched."
  (harness-computers-test-with
    (let* ((sid (harness-computers-test-session))
           (session (harness-call 'session/get sid))
           (decision (harness-computers-test-decision session nil)))
      (should (eq 'allow (plist-get decision :behavior)))
      (should-not (plist-member decision :computer)))))

;;;; Resources, projects, and the store

(ert-deftest harness-computers-resources-are-named-across-computers ()
  "A resource knows its computer and the path of that computer.
Projects are the git repositories among them, across computers."
  (harness-computers-test-with
    (harness-computers-test-remote-record
     "box" :resources (list (list :kind "git-repo" :name "app" :path "/home/me/app" :branch "main")
                            (list :kind "directory" :name "media" :path "/home/me/media")
                            (list :kind "display" :name "desk" :path ":0")))
    (let ((resources (harness-call 'computer/resources))
          (repos (harness-call 'computer/resources nil "git-repo"))
          (projects (harness-call 'computer/projects)))
      (should (= 3 (length resources)))
      (should (equal '("app") (mapcar (lambda (r) (plist-get r :name)) repos)))
      (should (equal (harness-computers-test-id "box")
                     (plist-get (car repos) :computer)))
      (should (equal "box" (plist-get (car repos) :computer-name)))
      (should (equal '("app") (mapcar (lambda (r) (plist-get r :name)) projects)))
      (should (plist-get (car projects) :project)))))

(ert-deftest harness-computers-update-resources-replaces-one-kind ()
  "The harness replaces one kind of a computer's resources authoritatively.
What it reports reconciles: a resource of that kind the list leaves out
is gone, the other kinds are untouched, and it is not a client's call."
  (harness-computers-test-with
    (let* ((id (harness-computers-test-id "box"))
           (skills (lambda ()
                     (harness-call 'computer/resources id "skill")))
           (repos (lambda ()
                    (harness-call 'computer/resources id "git-repo"))))
      (harness-computers-test-remote-record
       "box" :resources (list (list :kind "git-repo" :name "app" :path "/home/me/app")
                              (list :kind "skill" :name "commit" :id "sk-one"
                                    :properties (list :name "commit" :fingerprint "fp-one"))
                              (list :kind "skill" :name "review" :id "sk-two"
                                    :properties (list :name "review" :fingerprint "fp-two"))))
      (should (equal '("commit" "review") (mapcar (lambda (r) (plist-get r :name))
                                                  (funcall skills))))
      ;; The report replaces the kind: a skill it leaves out is gone, and
      ;; the properties of the one it keeps are the answer's.
      (let ((record (harness-call
                     'computers/update-resources id "skill"
                     (list (list :kind "skill" :name "commit" :id "sk-one"
                                 :properties (list :name "commit"
                                                   :fingerprint "fp-changed"))))))
        (should (equal '("commit") (mapcar (lambda (r) (plist-get r :name))
                                           (funcall skills))))
        (should (equal "fp-changed"
                       (plist-get (plist-get (car (funcall skills)) :properties)
                                  :fingerprint)))
        ;; The answer is the computer as `computer/get' reads it.
        (should (equal id (plist-get record :id))))
      ;; The other kinds stay as they were.
      (should (equal '("app") (mapcar (lambda (r) (plist-get r :name))
                                      (funcall repos))))
      ;; A kind the computer no longer has at all empties.
      (harness-call 'computers/update-resources id "skill" nil)
      (should-not (funcall skills))
      (should (funcall repos))
      ;; The harness's own method: no client speaks it over ACP.
      (should-not (harness-acp--extension-allowed-p "computers/update-resources")))))

(ert-deftest harness-computers-the-registry-survives-a-save-and-load ()
  "The records that outlive the process come back, without a client or a
transport, and a computer no client runs on reads disconnected."
  (harness-computers-test-with
    (let* ((client (harness-computers-test-client '(:address "192.0.2.10")))
           (record (harness-computers-test-register
                    client "box" "the box" (list (list :kind "git-repo" :name "app" :path "/srv/app")))))
      (should (plist-get (harness-computers-get (harness-computers-test-id "box")) :mcp))
      (harness-computers--save)
      ;; What a new process loads.
      (setq harness-computers--loaded nil)
      (harness-computers-test--reset)
      (let ((loaded (progn (harness-computers--load)
                           (harness-computers-get (harness-computers-test-id "box")))))
        (should loaded)
        (should (equal "the box" (plist-get loaded :name)))
        (should (eq 'disconnected (plist-get loaded :state)))
        (should-not (plist-get loaded :client))
        (should-not (plist-get loaded :mcp))
        (should (consp (plist-get loaded :secret)))
        (should (equal '("app")
                       (mapcar (lambda (r) (plist-get r :name)) (plist-get loaded :resources))))
        (should (harness-computers--secret-ok-p loaded harness-computers-test-secret))))))

(ert-deftest harness-computers-every-change-is-announced ()
  "Registering, granting, preferring, controlling and removing a computer
each say so on the bus, with the computer it is about."
  (harness-computers-test-with
    (let ((events (harness-computers-test-subscribe))
          (client (harness-computers-test-client '(:address "192.0.2.10")))
          (sid nil)
          (id (harness-computers-test-id "box")))
      (setq sid (harness-computers-test-session))
      (harness-computers-test-register client "box" "the box")
      (harness-computers-grant sid id nil nil 'user)
      (harness-call 'computer/set-preference sid id)
      (harness-call 'computer/take-control id)
      (harness-call 'computer/release-control id)
      (let ((harness-acp--calling-client client))
        (harness-call 'computer/unregister id))
      (should (equal (list (list id 'registered) (list id 'granted)
                           (list id 'preferred) (list id 'control)
                           (list id 'control) (list id 'removed))
                     (reverse (car events)))))))

(provide 'harness-computers-test)
;;; harness-computers-test.el ends here
