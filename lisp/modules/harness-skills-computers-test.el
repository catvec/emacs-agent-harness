;;; harness-skills-computers-test.el --- Tests for skills as computer resources  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The skills module (harness-skills.el) with the computers module: a
;; computer advertises its skills as its own `skill' resources, a
;; registration, an attachment and a refresh reconcile them, a
;; disconnected computer keeps its metadata and loses its content, and a
;; session needs the computer and the `skills' capability before it may
;; read one.  The MCP transport of a computer is stubbed at
;; `harness-computers-call' where a test needs a content answer: what is tested
;; here is the lifecycle, the selection and the trust boundary, not the
;; socket, which harness-computer-endpoint-test covers.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)

(defvar harness-computers--computers)
(defvar harness-computers--client-info)
(defvar harness-computers--client-binding)
(defvar harness-computers--loaded)
(defvar harness-skills--cache)
(defvar harness-skills-directories)
(defvar harness-skills-computer-skills)
(defvar harness-acp--server-enabled)
(declare-function harness-acp-add-client "harness-acp" (&rest args))
(declare-function harness-computers-get "harness-computers" (id-or-name))
(declare-function harness-computers-grant "harness-computers" (session-id computer &optional capabilities window who))
(declare-function harness-computers-revoke "harness-computers" (session-id computer &optional capability who))

(defconst harness-skills-computers-test-modules
  '(store project config provider provider-demo tools session agent tools-agent perms readonly
    mcp acp computers tools-computers skills)
  "The modules every test loads, in the order they load.")

(defconst harness-skills-computers-test-secret
  "a-registration-secret-of-at-least-32-characters"
  "The secret a test client registers its computer with.")

(defun harness-skills-computers-test--reset ()
  "Forget every computer and skill this Emacs's earlier test made."
  (clrhash harness-computers--computers)
  (clrhash harness-computers--client-info)
  (clrhash harness-computers--client-binding)
  (clrhash harness-skills--cache)
  (setq harness-computers--loaded nil)
  (harness-computers--load))

(defmacro harness-skills-computers-test-with (&rest body)
  "Load the modules and a fresh registry, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (when (boundp 'harness-tools) (clrhash harness-tools))
     (let ((harness-acp--server-enabled nil)
           (harness-skills-computers-test--read-skill nil)
           ;; No test reads the developer's own skills.
           (harness-skills-directories nil)
           (harness-skills-computer-skills t))
       (dolist (m harness-skills-computers-test-modules)
         (harness-test-load-module m))
       (clrhash harness-sessions)
       (harness-skills-computers-test--reset)
       (cl-letf (((symbol-function 'harness-computers-call)
                  #'harness-skills-computers-test--transport))
         (let ((default-directory (harness-test-temp-dir)))
           ,@body)))))

(defun harness-skills-computers-test-client (&optional remote)
  "Return a client of a test transport, on another computer when REMOTE."
  (harness-acp-add-client 'test :writer #'ignore :remote remote))

(defun harness-skills-computers-test-session (&rest plist)
  "Create a demo session with PLIST and return its id."
  (plist-get (apply #'harness-call 'session/create :cwd (harness-test-temp-dir)
                    :model "demo:scripted"
                    :permission-mode (or (plist-get plist :permission-mode) 'yolo)
                    plist)
             :id))

(defun harness-skills-computers-test-skill (name &optional properties)
  "Return a `skill' resource of a computer, called NAME, with PROPERTIES.
PROPERTIES defaults to a version, a fingerprint and no files."
  (let ((properties (or properties
                        (list :id (concat "sk-" (substring (secure-hash 'sha1 name) 0 16))
                              :name name
                              :description (format "%s, from a test computer." name)
                              :source "global"
                              :origin "claude"
                              :version "1.0"
                              :version-source "explicit"
                              :version-key "1.0"
                              :fingerprint (concat "fp-" (substring (secure-hash 'sha256 name) 0 32))
                              :files nil
                              :relative name))))
    (list :kind "skill"
          :id (plist-get properties :id)
          :name (or (plist-get properties :name) name)
          :path (format "~/%s" name)
          :properties properties)))

(defun harness-skills-computers-test-load (name &optional cwd opts)
  "Load the skill NAME as a person's read, waiting for a computer's answer.
`skills/load' answers at once for a skill of this harness and with a
promise for one of a computer, as a person's ACP request does."
  (harness-test-await (harness-as-promise (harness-call 'skills/load name cwd opts))))

(defun harness-skills-computers-test-register (&optional resources id name capabilities)
  "Register a computer ID (NAME) offering RESOURCES with CAPABILITIES.
Registering happens as a client on that computer; the resource list is
exactly what the client advertised, so a second call reconciles."
  (let* ((client (harness-skills-computers-test-client t))
         (harness-acp--calling-client client))
    (plist-get (harness-call
                'computer/register
                :computer (list :id (or id "cmp-box") :name (or name "box")
                                :host "box.example.test"
                                :capabilities (or capabilities '("view" "skills")))
                :secret harness-skills-computers-test-secret
                :resources resources
                :servers (list (list :name "computer" :title "Computer")))
               :computer)))

(defun harness-skills-computers-test-disconnect (id)
  "Make the client serving computer ID leave, as a dropped connection does.
The computer stays registered, reads `disconnected', and its client is
forgotten, so another client can attach when it comes back."
  (let ((client (plist-get (harness-computers-get id) :client)))
    (unless client
      (signal 'harness-error (list (format "no client serves %s" id))))
    (harness-computers--on-client-left client)))

(defun harness-skills-computers-test-may-read-p (session computer)
  "Return whether SESSION may read a skill from COMPUTER, honestly."
  (and (harness-method-exists-p 'computers/check)
       (plist-get (harness-call 'computers/check session
                                :computer computer
                                :capability "skills")
                  :ok)))

(defvar harness-skills-computers-test--read-skill nil
  "The skill a test's computer transport answers a read with, or nil.")

(defun harness-skills-computers-test--transport (computer tool input &optional server ctx)
  "Answer COMPUTER's TOOL call with INPUT as the computer's own MCP server does.
Only the `skills' tool is served, and only for the skill the test set in
`harness-skills-computers-test--read-skill': the answer is the shape
`harness-computer-endpoint-skills-read' returns.  A test that reads
nothing answers nothing, and one that needs another answer stubs this
function itself."
  (ignore server ctx)
  (unless (equal tool "skills")
    (signal 'harness-error (list (format "no tool %s of a computer is served here" tool))))
  (let ((properties (plist-get harness-skills-computers-test--read-skill :properties)))
    (unless properties
      (signal 'harness-error (list "no skill is being read in this test")))
    (harness-resolved
     (list :content "the answer"
           :is-error nil
           :structured
           (if (plist-get input :file)
               (list :skill properties
                     :file (plist-get input :file)
                     :content "checklist\n"
                     :fingerprint (plist-get properties :fingerprint))
             (list :skill properties
                   :content "Follow these instructions carefully.\n"
                   :fingerprint (plist-get properties :fingerprint)))))))

(defun harness-skills-computers-test-load (name &optional cwd opts)
  "Load the skill NAME as a person's read, waiting for a computer's answer.
`skills/load' answers at once for a skill of this harness and with a
promise for one of a computer, as a person's ACP request does."
  (harness-test-await (harness-as-promise (harness-call 'skills/load name cwd opts))))

(defun harness-skills-computers-test-register (&optional resources id name capabilities)
  "Register a computer ID (NAME) offering RESOURCES with CAPABILITIES.
Registering happens as a client on that computer; the resource list is
exactly what the client advertised, so a second call reconciles."
  (let* ((client (harness-skills-computers-test-client t))
         (harness-acp--calling-client client))
    (plist-get (harness-call
                'computer/register
                :computer (list :id (or id "cmp-box") :name (or name "box")
                                :host "box.example.test"
                                :capabilities (or capabilities '("view" "skills")))
                :secret harness-skills-computers-test-secret
                :resources resources
                :servers (list (list :name "computer" :title "Computer")))
               :computer)))

(defun harness-skills-computers-test-may-read-p (session computer)
  "Return whether SESSION may read a skill from COMPUTER, honestly."
  (and (harness-method-exists-p 'computers/check)
       (plist-get (harness-call 'computers/check session
                                :computer computer
                                :capability "skills")
                  :ok)))

(defmacro harness-skills-computers-test-with-read (skill &rest body)
  "Answer SKILL's read for BODY, as the computer's own `skills' tool does.
The answer is the shape `harness-computer-endpoint-skills-read' returns:
the skill's metadata, its instructions, its fingerprint, and
`checklist\n' for any supporting file."
  (declare (indent 1))
  `(let ((properties (plist-get ,skill :properties)))
     (cl-letf (((symbol-function 'harness-computers-call)
                (lambda (_computer tool input &optional _server _ctx)
                  (unless (equal tool "skills")
                    (signal 'harness-error (list (format "no tool %s" tool))))
                  (let ((structured
                         (if (plist-get input :file)
                             (list :skill properties
                                   :file (plist-get input :file)
                                   :content "checklist\n"
                                   :fingerprint (plist-get properties :fingerprint))
                           (list :skill properties
                                 :content "Follow these instructions carefully.\n"
                                 :fingerprint (plist-get properties :fingerprint)))))
                    (harness-resolved
                     (list :content "the answer"
                           :is-error nil
                           :structured structured))))))
       ,@body)))

(defun harness-skills-computers-test-load (name &optional cwd opts)
  "Load the skill NAME as a person's read, waiting for a computer's answer.
`skills/load' answers at once for a skill of this harness and with a
promise for one of a computer, as a person's ACP request does."
  (harness-test-await (harness-as-promise (harness-call 'skills/load name cwd opts))))

(defun harness-skills-computers-test-register (&optional resources id name capabilities)
  "Register a computer ID (NAME) offering RESOURCES with CAPABILITIES.
Registering happens as a client on that computer; the resource list is
exactly what the client advertised, so a second call reconciles."
  (let* ((client (harness-skills-computers-test-client t))
         (harness-acp--calling-client client))
    (plist-get (harness-call
                'computer/register
                :computer (list :id (or id "cmp-box") :name (or name "box")
                                :host "box.example.test"
                                :capabilities (or capabilities '("view" "skills")))
                :secret harness-skills-computers-test-secret
                :resources resources
                :servers (list (list :name "computer" :title "Computer")))
               :computer)))

(defun harness-skills-computers-test-may-read-p (session computer)
  "Return whether SESSION may read a skill from COMPUTER, honestly."
  (and (harness-method-exists-p 'computers/check)
       (plist-get (harness-call 'computers/check session
                                :computer computer
                                :capability "skills")
                  :ok)))

(defun harness-skills-computers-test-refresh-computer (computer resources)
  "Answer COMPUTER's `skills' refresh with RESOURCES, and register them.
It is what `skills/refresh' does with a computer that answers: the
computer's `skill' resources are replaced authoritatively."
  (cl-letf (((symbol-function 'harness-computers-call)
             (lambda (_computer tool input &optional _server _ctx)
               (unless (and (equal tool "skills") (equal (plist-get input :action) "refresh"))
                 (signal 'harness-error (list (format "unexpected call %s" tool))))
               (harness-resolved
                (list :content "the answer" :is-error nil
                      :structured (list :skills (mapcar (lambda (r) (plist-get r :properties))
                                                        resources)
                                        :count (length resources)
                                        :diagnostics nil))))))
    (harness-test-await (harness-call 'skills/refresh computer))))

;;;; Registering and reconciling

(ert-deftest harness-skills-computers-advertised-skills-are-resources ()
  "A computer that registers with its skills lists them with their
provenance, owner, version and a qualified reference; the harness's own
skills come first, and none is fetched to list it."
  (harness-skills-computers-test-with
    (let* ((resources (list (harness-skills-computers-test-skill "commit")
                            (harness-skills-computers-test-skill "review")))
           (record (harness-skills-computers-test-register resources)))
      (should (equal "cmp-box" (plist-get record :id)))
      (should (= 2 (length (harness-call 'computer/resources nil "skill"))))
      (let* ((entries (harness-call 'skills/list (harness-test-temp-dir)))
             (commit (cl-find "cmp-box/commit" entries
                              :key (lambda (e) (plist-get e :reference)) :test #'equal)))
        (should commit)
        (should (equal "cmp-box" (plist-get commit :owner)))
        (should (equal "box" (plist-get commit :owner-name)))
        (should (equal "1.0" (plist-get commit :version)))
        (should (equal "cmp-box/commit@1.0" (plist-get commit :pin)))
        (should (eq 'global (plist-get commit :source)))
        (should (equal "claude" (plist-get commit :origin)))
        (should (equal "ready" (plist-get commit :state)))
        ;; A listing is metadata: no content came over.
        (should-not (plist-member commit :content))))))

(ert-deftest harness-skills-computers-a-second-registration-reconciles ()
  "Registering again replaces the list a computer advertises: a skill it
no longer has is gone, with no stale entry and no duplicate."
  (harness-skills-computers-test-with
    (harness-skills-computers-test-register
     (list (harness-skills-computers-test-skill "commit")
           (harness-skills-computers-test-skill "review")))
    (should (= 2 (length (harness-call 'computer/resources nil "skill"))))
    ;; The same skill, one gone and one new: registering again is the
    ;; authority, as it is for its git repositories.
    (harness-skills-computers-test-register
     (list (harness-skills-computers-test-skill "commit")
           (harness-skills-computers-test-skill "deploy")))
    (let ((references (mapcar (lambda (e) (plist-get e :reference))
                              (harness-call 'skills/list))))
      (should (member "cmp-box/commit" references))
      (should (member "cmp-box/deploy" references))
      (should-not (member "cmp-box/review" references)))
    (should (= 2 (length (harness-call 'computer/resources nil "skill"))))))

(ert-deftest harness-skills-computers-refresh-reconciles-authoritatively ()
  "A refresh asks the computer, and what it answers replaces its skills:
an addition registers and a removal never lingers."
  (harness-skills-computers-test-with
    (let ((session (harness-skills-computers-test-session)))
      (harness-skills-computers-test-register
       (list (harness-skills-computers-test-skill "commit")))
      (harness-computers-grant session "cmp-box" '("skills"))
      (let ((answer (harness-skills-computers-test-refresh-computer
                     "cmp-box"
                     (list (harness-skills-computers-test-skill "commit")
                           (harness-skills-computers-test-skill "deploy")))))
        (should (plist-get answer :refreshed))
        (should (equal "ready" (plist-get (car (plist-get answer :computers)) :state)))
        (should (= 2 (plist-get (car (plist-get answer :computers)) :skills))))
      (let ((references (mapcar (lambda (e) (plist-get e :reference))
                                (harness-call 'skills/list nil (list :session-id session)))))
        (should (member "cmp-box/commit" references))
        (should (member "cmp-box/deploy" references)))
      ;; And a skill the computer no longer has goes with the next answer.
      (harness-skills-computers-test-refresh-computer
       "cmp-box" (list (harness-skills-computers-test-skill "deploy")))
      (should (equal '("cmp-box/deploy")
                     (mapcar (lambda (e) (plist-get e :reference))
                             (harness-call 'skills/list nil (list :session-id session))))))))

(ert-deftest harness-skills-computers-refresh-says-when-a-computer-is-gone ()
  "A refresh of a computer with no client says `offline', and one whose
implementation cannot serve skills says `unavailable'; neither invents a
skill and neither fails the others."
  (harness-skills-computers-test-with
    (harness-skills-computers-test-register
     (list (harness-skills-computers-test-skill "commit"))
     "cmp-box" "box" '("view"))
    (let ((answer (harness-test-await (harness-call 'skills/refresh "cmp-box"))))
      (should (equal "unavailable" (plist-get (car (plist-get answer :computers)) :state))))
    ;; A computer that is no more.
    (let ((answer (harness-test-await (harness-call 'skills/refresh "cmp-nope"))))
      (should (equal "unknown" (plist-get (car (plist-get answer :computers)) :state)))))
  ;; A disconnected computer answers `offline'.
  (harness-skills-computers-test-with
    (harness-skills-computers-test-register
     (list (harness-skills-computers-test-skill "commit")))
    (let ((record (harness-computers-get "cmp-box")))
      (puthash "cmp-box" (plist-put record :state 'disconnected)
               harness-computers--computers))
    (let ((answer (harness-test-await (harness-call 'skills/refresh "cmp-box"))))
      (should (equal "offline" (plist-get (car (plist-get answer :computers)) :state))))))

;;;; Reading, offline and stale content

(ert-deftest harness-skills-computers-reads-a-skill-from-its-computer ()
  "A selected skill is fetched from its computer at the fingerprint the
selection saw, and the answer keeps the source identity end to end."
  (harness-skills-computers-test-with
    (let* ((session (harness-skills-computers-test-session))
           (skill (harness-skills-computers-test-skill "commit"))
           (loaded nil))
      (harness-skills-computers-test-register (list skill))
      (harness-computers-grant session "cmp-box" '("skills"))
      (setq harness-skills-computers-test--read-skill skill)
      (setq loaded (harness-skills-computers-test-load "cmp-box/commit" nil
                                 (list :session-id session)))
      (should (equal "Follow these instructions carefully.\n" (plist-get loaded :content)))
      (should (equal "cmp-box" (plist-get loaded :owner)))
      (should (equal "cmp-box/commit" (plist-get loaded :reference)))
      (should (equal "1.0" (plist-get loaded :version)))
      (should (equal (plist-get (plist-get skill :properties) :fingerprint)
                     (plist-get loaded :selected-fingerprint)))
      (should-not (plist-get loaded :changed))
      ;; A supporting file comes from the same computer.
      (let ((file (harness-skills-computers-test-load "cmp-box/commit" nil
                                (list :session-id session :file "checklist.md"))))
        (should (equal "checklist.md" (plist-get file :file)))
        (should (equal "checklist\n" (plist-get file :content)))))))

(ert-deftest harness-skills-computers-offline-keeps-metadata-and-loses-content ()
  "A disconnected computer keeps its skills visible and marks them
offline; loading one says so instead of serving a cached copy, and a
reconnect makes them readable again without a second registration."
  (harness-skills-computers-test-with
    (let* ((session (harness-skills-computers-test-session))
           (skill (harness-skills-computers-test-skill "commit")))
      (harness-skills-computers-test-register (list skill))
      (harness-computers-grant session "cmp-box" '("skills"))
      (harness-skills-computers-test-disconnect "cmp-box")
      ;; The metadata is known, and says it cannot be read now.
      (let ((entry (cl-find "cmp-box/commit" (harness-call 'skills/list nil
                                                           (list :session-id session))
                            :key (lambda (e) (plist-get e :reference)) :test #'equal)))
        (should entry)
        (should (equal "offline" (plist-get entry :state))))
      ;; Reading it is refused, and no content was cached to serve instead.
      (let ((err (condition-case err
                     (harness-skills-computers-test-load "cmp-box/commit" nil
                                   (list :session-id session))
                   (harness-error (error-message-string err)))))
        (should (stringp err))
        (should (string-search "not connected" err)))
      ;; The computer attaches again: the same record, no re-registration.
      (let* ((client (harness-skills-computers-test-client t))
             (harness-acp--calling-client client))
        (harness-call 'computer/attach "cmp-box" harness-skills-computers-test-secret))
      (should (equal 'connected
                     (harness-computers--state
                      (plist-get (harness-computers-get "cmp-box") :state))))
      (setq harness-skills-computers-test--read-skill skill)
      (should (equal "Follow these instructions carefully.\n"
                     (plist-get (harness-skills-computers-test-load "cmp-box/commit" nil
                                              (list :session-id session))
                                :content))))))

(ert-deftest harness-skills-computers-a-changed-skill-is-reported-not-substituted ()
  "A skill that changed between selection and retrieval is reported as
changed, and never silently presented as the version that was selected."
  (harness-skills-computers-test-with
    (let* ((session (harness-skills-computers-test-session))
           (skill (harness-skills-computers-test-skill "commit")))
      (harness-skills-computers-test-register (list skill))
      (harness-computers-grant session "cmp-box" '("skills"))
      ;; The computer's copy is another version now.
      (cl-letf (((symbol-function 'harness-computers-call)
                 (lambda (_computer _tool input &optional _server _ctx)
                   (harness-resolved
                    (list :content "the answer" :is-error nil
                          :structured (list :skill (list :name "commit"
                                                         :fingerprint "fp-another-version-000000"
                                                         :files nil)
                                            :content "Other instructions.\n"
                                            :fingerprint "fp-another-version-000000"))))))
        (let ((loaded (harness-skills-computers-test-load "cmp-box/commit" nil
                                    (list :session-id session))))
          (should (plist-get loaded :changed))
          (should (equal "fp-another-version-000000" (plist-get loaded :fingerprint)))
          ;; A pin at the version the selection saw refuses the new one.
          (let ((harness-skills-computers-test-chosen
                 (plist-get (plist-get skill :properties) :fingerprint)))
            (ignore harness-skills-computers-test-chosen)))))
    ;; The computer refuses a read at a fingerprint it no longer has: the
    ;; transport answer is an error, and the harness reports it.
    (let* ((session (harness-skills-computers-test-session))
           (skill (harness-skills-computers-test-skill "commit")))
      (harness-skills-computers-test-register (list skill))
      (harness-computers-grant session "cmp-box" '("skills"))
      ;; The harness registers a fingerprint it saw; by the time the read
      ;; reaches the computer its copy is another one, so the computer
      ;; refuses the pin rather than serving what it has now.
      (let ((pinned (plist-get (plist-get skill :properties) :fingerprint)))
        (cl-letf (((symbol-function 'harness-computers-call)
                   (lambda (_computer _tool input &optional _server _ctx)
                     (if (equal pinned (plist-get input :fingerprint))
                         (harness-resolved
                          (list :content "The skill commit changed since it was selected"
                                :is-error t))
                       (signal 'harness-error (list "the pin was not sent"))))))
          (let ((err (condition-case err
                         (harness-skills-computers-test-load
                          (format "cmp-box/commit#%s" pinned) nil
                          (list :session-id session))
                       (harness-error (error-message-string err)))))
            (should (string-search "changed since it was selected" err))))))))

;;;; Trust: listing and loading grant nothing

(ert-deftest harness-skills-computers-listing-grants-nothing ()
  "A skill's metadata is listed whether or not the session may read it;
the entry says `not-granted', and no grant was added by listing it."
  (harness-skills-computers-test-with
    (let* ((session (harness-skills-computers-test-session))
           (skill (harness-skills-computers-test-skill "commit")))
      (harness-skills-computers-test-register (list skill))
      (let ((entry (cl-find "cmp-box/commit" (harness-call 'skills/list nil
                                                           (list :session-id session))
                            :key (lambda (e) (plist-get e :reference)) :test #'equal)))
        (should entry)
        (should (equal "not-granted" (plist-get entry :state)))
        ;; Nothing was granted by looking.
        (should-not (harness-skills-computers-test-may-read-p session "cmp-box"))
        ;; Reading it fails, and says a grant is what it needs.
        (let ((err (condition-case err
                       (harness-skills-computers-test-load "cmp-box/commit" nil
                                     (list :session-id session))
                     (harness-error (error-message-string err)))))
          (should (string-search "may not read skills" err)))
        ;; A grant of another capability is no grant of skills.
        (harness-computers-grant session "cmp-box" '("view"))
        (should-not (harness-skills-computers-test-may-read-p session "cmp-box"))
        (harness-computers-grant session "cmp-box" '("skills"))
        (should (harness-skills-computers-test-may-read-p session "cmp-box"))))))

(ert-deftest harness-skills-computers-loading-grants-nothing ()
  "Loading a skill's instructions runs nothing and grants nothing: a
file it names is not written, a command it names is not run, and the
session's grants are what they were."
  (harness-skills-computers-test-with
    (let* ((session (harness-skills-computers-test-session))
           (skill (harness-skills-computers-test-skill
                   "install"
                   (list :id "sk-install" :name "install"
                         :description "Install things."
                         :source "project" :origin "harness"
                         :version "2.0" :version-key "2.0"
                         :fingerprint "fp-0123456789abcdef0123456789abcdef"
                         :files '("run.sh"))))
           (before nil) (after nil))
      (harness-skills-computers-test-register (list skill))
      (harness-computers-grant session "cmp-box" '("skills"))
      (setq before (harness-call 'computer/access session))
      (cl-letf (((symbol-function 'harness-computers-call)
                 (lambda (_computer _tool _input &optional _server _ctx)
                   (harness-resolved
                    (list :content "the answer" :is-error nil
                          :structured
                          (list :skill (plist-get skill :properties)
                                :content "Run run.sh and install everything.\n"
                                :fingerprint (plist-get (plist-get skill :properties)
                                                        :fingerprint)))))))
        (should (string-search "Run run.sh"
                               (plist-get (harness-skills-computers-test-load "cmp-box/install" nil
                                                        (list :session-id session))
                                          :content))))
      (setq after (harness-call 'computer/access session))
      (should (equal (plist-get before :computers) (plist-get after :computers)))
      ;; The tool that reads a skill runs on no computer of its own and is
      ;; a read of the harness, not of a shell.
      (let ((tool (harness-tool-get "skill_load")))
        (should (eq 'read (harness-tool-kind tool)))))))

(ert-deftest harness-skills-computers-no-computer-is-no-grant ()
  "A session that may use no computer reads no skill of one, even when
the skill is listed and its owner is named."
  (harness-skills-computers-test-with
    (let* ((session (harness-skills-computers-test-session))
           (skill (harness-skills-computers-test-skill "commit")))
      (harness-skills-computers-test-register (list skill))
      (let ((err (condition-case err
                     (harness-skills-computers-test-load "cmp-box/commit" nil
                                   (list :session-id session))
                   (harness-error (error-message-string err)))))
        (should (string-search "may not read skills" err))))))

;;;; Names, conflicts and versions

(ert-deftest harness-skills-computers-a-name-on-two-owners-is-ambiguous ()
  "Two computers with different content under one name are reported as
ambiguous with both references, never resolved by first-wins."
  (harness-skills-computers-test-with
    (let ((session (harness-skills-computers-test-session))
          (one (harness-skills-computers-test-skill
                "commit"
                (list :id "sk-one" :name "commit" :description "First."
                      :source "global" :origin "claude" :version "1.0" :version-key "1.0"
                      :fingerprint "fp-11111111111111111111111111111111" :files nil)))
          (two (harness-skills-computers-test-skill
                "commit"
                (list :id "sk-two" :name "commit" :description "Second."
                      :source "global" :origin "claude" :version "2.0" :version-key "2.0"
                      :fingerprint "fp-22222222222222222222222222222222" :files nil))))
      (harness-skills-computers-test-register (list one) "cmp-one" "one")
      (harness-skills-computers-test-register (list two) "cmp-two" "two")
      (harness-computers-grant session "cmp-one" '("skills"))
      (harness-computers-grant session "cmp-two" '("skills"))
      (let ((err (condition-case err
                     (harness-skills-computers-test-load "commit" nil (list :session-id session))
                   (harness-error (error-message-string err)))))
        (should (string-search "more than one owner" err))
        (should (string-search "cmp-one/commit" err))
        (should (string-search "cmp-two/commit" err)))
      ;; Each named owner reads its own, and never the other.
      (setq harness-skills-computers-test--read-skill one)
      (should (equal "Follow these instructions carefully.\n"
                     (plist-get (harness-skills-computers-test-load "cmp-one/commit" nil
                                              (list :session-id session))
                                :content)))
      (setq harness-skills-computers-test--read-skill two)
      (should (equal "Follow these instructions carefully.\n"
                     (plist-get (harness-skills-computers-test-load "cmp-two/commit" nil
                                              (list :session-id session))
                                :content))))))

(ert-deftest harness-skills-computers-one-name-one-content-is-not-ambiguous ()
  "Copies of one skill with the same fingerprint are one answer: which
owner served it cannot change what is read."
  (harness-skills-computers-test-with
    (let* ((session (harness-skills-computers-test-session))
           (properties (list :id "sk-shared" :name "shared" :description "Shared."
                             :source "global" :origin "claude"
                             :version "1.0" :version-key "1.0"
                             :fingerprint "fp-33333333333333333333333333333333"
                             :files nil))
           (one (harness-skills-computers-test-skill "shared" properties))
           (two (harness-skills-computers-test-skill "shared" properties)))
      (harness-skills-computers-test-register (list one) "cmp-one" "one")
      (harness-skills-computers-test-register (list two) "cmp-two" "two")
      (harness-computers-grant session "cmp-one" '("skills"))
      (harness-computers-grant session "cmp-two" '("skills"))
      (setq harness-skills-computers-test--read-skill one)
      (let ((loaded (harness-skills-computers-test-load "shared" nil (list :session-id session))))
        (should loaded)
        ;; The owner it came from is named, and it is one of the two.
        (should (member (plist-get loaded :owner) '("cmp-one" "cmp-two")))))))

(ert-deftest harness-skills-computers-a-pin-selects-one-version ()
  "A version or a fingerprint selects one copy reproducibly; a pin that
matches nothing is `version-mismatch' and never another version."
  (harness-skills-computers-test-with
    (let ((session (harness-skills-computers-test-session))
          (one (harness-skills-computers-test-skill
                "commit"
                (list :id "sk-one" :name "commit" :description "First."
                      :source "global" :origin "claude" :version "1.0" :version-key "1.0"
                      :fingerprint "fp-11111111111111111111111111111111" :files nil)))
          (two (harness-skills-computers-test-skill
                "commit"
                (list :id "sk-two" :name "commit" :description "Second."
                      :source "global" :origin "claude" :version "2.0" :version-key "2.0"
                      :fingerprint "fp-22222222222222222222222222222222" :files nil))))
      (harness-skills-computers-test-register (list one) "cmp-one" "one")
      (harness-skills-computers-test-register (list two) "cmp-two" "two")
      (harness-computers-grant session "cmp-one" '("skills"))
      (harness-computers-grant session "cmp-two" '("skills"))
      ;; A pin names the owner and the version, and that copy is what is read.
      (setq harness-skills-computers-test--read-skill two)
      (should (equal "cmp-two"
                     (plist-get (harness-skills-computers-test-load "cmp-two/commit@2.0" nil
                                              (list :session-id session))
                                :owner)))
      ;; A pin on the other computer's version is that computer's copy.
      (setq harness-skills-computers-test--read-skill one)
      (should (equal "cmp-one"
                     (plist-get (harness-skills-computers-test-load "cmp-one/commit@1.0" nil
                                              (list :session-id session))
                                :owner)))
      ;; A version no copy has is refused, and says what there is.
      (let ((err (condition-case err
                     (harness-skills-computers-test-load "commit@9.9" nil (list :session-id session))
                   (harness-error (error-message-string err)))))
        (should (string-search "version 9.9" err))
        ;; Neither version was substituted for the one asked for.
        (should-not (string-search "Follow these" err)))
      ;; A fingerprint is a version too: it pins the exact bytes.
      (setq harness-skills-computers-test--read-skill two)
      (should (equal "fp-22222222222222222222222222222222"
                     (plist-get (harness-skills-computers-test-load
                                 "commit#fp-22222222222222222222222222222222"
                                 nil (list :session-id session))
                                :fingerprint))))))

(ert-deftest harness-skills-computers-a-source-and-a-computer-narrow-a-load ()
  "`skill_load' selects by computer and by source explicitly, so two
copies under one name are no ambiguity once one is named."
  (harness-skills-computers-test-with
    (let ((session (harness-skills-computers-test-session))
          (one (harness-skills-computers-test-skill
                "commit"
                (list :id "sk-one" :name "commit" :description "First."
                      :source "global" :origin "claude" :version "1.0" :version-key "1.0"
                      :fingerprint "fp-11111111111111111111111111111111" :files nil)))
          (two (harness-skills-computers-test-skill
                "commit"
                (list :id "sk-two" :name "commit" :description "Second."
                      :source "project" :origin "harness" :version "1.0" :version-key "1.0"
                      :fingerprint "fp-22222222222222222222222222222222" :files nil))))
      (harness-skills-computers-test-register (list one) "cmp-one" "one")
      (harness-skills-computers-test-register (list two) "cmp-two" "two")
      (harness-computers-grant session "cmp-one" '("skills"))
      (harness-computers-grant session "cmp-two" '("skills"))
      (setq harness-skills-computers-test--read-skill two)
      (let ((loaded (harness-skills-computers-test-load "commit" nil
                                  (list :session-id session
                                        :computer "cmp-two" :source "project"))))
        (should (equal "cmp-two" (plist-get loaded :owner)))
        (should (eq 'project (plist-get loaded :source)))))))

;;;; References a message names

(ert-deftest harness-skills-computers-a-message-reference-is-fetched-too ()
  "A message naming a computer's skill has its content attached, as a
message naming the harness's own does, and the answer names the owner;
a reference nothing can serve is left as it was written."
  (harness-skills-computers-test-with
    (let* ((session (harness-skills-computers-test-session))
           (skill (harness-skills-computers-test-skill "commit")))
      (harness-skills-computers-test-register (list skill))
      (harness-computers-grant session "cmp-box" '("skills"))
      (setq harness-skills-computers-test--read-skill skill)
      (let ((answer (harness-test-await
                     (harness-as-promise
                      (harness-call 'skills/expand
                                    "please @skill:cmp-box/commit then stop\n@skill:cmp-nope/absent"
                                    (harness-test-temp-dir)
                                    (list :session-id session))))))
        (should (string-match-p "````*markdown skill:cmp-box/commit"
                                (plist-get answer :text)))
        (should (string-search "Follow these instructions carefully."
                               (plist-get answer :text)))
        (should (equal '("cmp-box/commit")
                       (mapcar (lambda (s) (plist-get s :reference))
                               (plist-get answer :skills))))
        ;; The name nothing serves is still in the text, untouched.
        (should (string-search "@skill:cmp-nope/absent" (plist-get answer :text)))))))

(ert-deftest harness-skills-computers-the-prompt-index-names-the-owners ()
  "The index the model reads names a computer's skill by its qualified
reference and says which registered skills it cannot read now."
  (harness-skills-computers-test-with
    (let* ((session (harness-skills-computers-test-session))
           (ready (harness-skills-computers-test-skill "commit"))
           (other (harness-skills-computers-test-skill "deploy")))
      (harness-skills-computers-test-register (list ready other))
      (harness-computers-grant session "cmp-box" '("skills"))
      (let ((prompt (harness-skills-system-prompt-filter
                     "Base."
                     (harness-call 'session/get session))))
        (should (string-search "- cmp-box/commit" prompt))
        (should (string-search "skill_load" prompt))
        (should (string-search "OWNER/NAME" prompt)))
      ;; A computer the session may not read says so, and stays listed.
      (harness-computers-revoke session "cmp-box" "skills")
      (let ((prompt (harness-skills-system-prompt-filter
                     "Base."
                     (harness-call 'session/get session))))
        (should (string-search "not readable now" prompt))
        (should (string-search "cmp-box/commit (not-granted)" prompt))))))

;;;; What the profile selects

(ert-deftest harness-skills-computers-a-selection-resolves-against-the-computers ()
  "A session's selection is durable intent: it resolves against the
skills its computers offer now, ready ones are named, and a missing one
or an offline one is reported without failing the rest."
  (harness-skills-computers-test-with
    (let* ((session (harness-skills-computers-test-session))
           (skill (harness-skills-computers-test-skill "commit")))
      (harness-skills-computers-test-register (list skill))
      (harness-computers-grant session "cmp-box" '("skills"))
      (let ((answer (harness-call 'skills/selection session
                                  (list :selection '("cmp-box/commit" "?cmp-box/absent"
                                                     "cmp-box/other")))))
        (should (equal '("ready" "optional-missing" "missing")
                       (mapcar (lambda (e) (plist-get e :state))
                               (plist-get answer :selection))))
        (should (equal "cmp-box/commit"
                       (plist-get (car (plist-get answer :entries)) :reference)))
        (should (= 2 (length (plist-get answer :unavailable)))))
      ;; The selection is remembered on the session, and read back.
      (harness-call 'skills/select session '("cmp-box/commit"))
      (should (equal '("cmp-box/commit")
                     (harness-skills-session-selection
                      (harness-call 'session/get session)))))))

(ert-deftest harness-skills-computers-a-selection-copies-no-grant ()
  "Selecting a skill grants nothing: the selection says not-granted for a
computer the session may not use, and the computer's access is as it was."
  (harness-skills-computers-test-with
    (let ((session (harness-skills-computers-test-session))
          (skill (harness-skills-computers-test-skill "commit")))
      (harness-skills-computers-test-register (list skill))
      (let ((answer (harness-call 'skills/selection session
                                  (list :selection '("cmp-box/commit")))))
        (should (equal "not-granted"
                       (plist-get (car (plist-get answer :selection)) :state)))
        (should-not (plist-get answer :entries))
        (should-not (harness-skills-computers-test-may-read-p session "cmp-box"))))))

(provide 'harness-skills-computers-test)
;;; harness-skills-computers-test.el ends here