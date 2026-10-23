;;; harness-ui-access-test.el --- Tests for the access view of a session  -*- lexical-binding: t; -*-

;;; Commentary:

;; The access view (harness-ui-access.el) against the real state layer,
;; the permission chain, the access module, the demo provider and the
;; in-process ACP connection: its directories follow grants made
;; anywhere, its jail changes the session's access, and its judgements
;; are the chat's own tool-call blocks, [Approve] included.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-provider-demo--delay)
(defvar harness-provider-demo-script-override)
(defvar harness-ui--sessions)
(defvar harness-perms--allowed-dirs)
(defvar harness-perms--session-rules)
(defvar harness-perms--turn-dirs)
(defvar harness-perms-rules)
(defvar harness-access--judged)
(defvar harness-ui-access--describe)
(defvar harness-ui-access--judgements)
(defvar harness-ui-map)

(defmacro harness-ui-access-test-with (&rest body)
  "Load the harness, the access module and the UI with the access view, run BODY.
SID names a fresh session in ask mode."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent tools-fs perms readonly
                          access acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-perms--allowed-dirs)
     (clrhash harness-access--judged)
     (harness-define-tool "test_fetch" :label "Test fetch" :kind 'net :description "Fetch nothing."
                          :subject (lambda (input) (plist-get input :url))
                          :handler (lambda (_input _ctx) (harness-tool-ok "fetched")))
     (dolist (m '(ui ui-compose ui-chat ui-pending ui-access))
       (harness-test-load-module m))
     (clrhash harness-ui--sessions)
     (let* ((harness-acp-token nil)
            (harness-provider-demo--delay 0.005)
            (default-directory dir)
            (sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted"
                                          :permission-mode 'ask)
                            :id)))
       (unwind-protect
           (progn ,@body)
         (dolist (b (buffer-list))
           (when (with-current-buffer b (derived-mode-p 'harness-ui-access-mode)) (kill-buffer b)))
         (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) harness-chat--buffers)
         (clrhash harness-chat--buffers)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-access-test-open (sid &optional section)
  "Open the access view of SID at SECTION, wait for it to be drawn, return it."
  (let ((buffer (harness-access sid section)))
    (set-buffer buffer)
    (harness-test-wait (lambda () (with-current-buffer buffer harness-ui-access--describe)) 5 "the view drawn")
    buffer))

(defun harness-ui-access-test-text ()
  "Return the text of the current buffer, without properties."
  (buffer-substring-no-properties (point-min) (point-max)))

(defun harness-ui-access-test-wait-text (regexp &optional absent)
  "Wait until the view's text matches REGEXP, or no longer does when ABSENT."
  (harness-test-wait (lambda ()
                       (let ((found (string-match-p regexp (harness-ui-access-test-text))))
                         (if absent (not found) found)))
                     5 (format "%s %s" (if absent "no" "a") regexp)))

(defun harness-ui-access-test-row (dir)
  "Return the text of the row of DIR in the view."
  (let ((pos (harness-ui-access--find-anchor (cons 'dir dir))))
    (should pos)
    (save-excursion (goto-char pos)
                    (buffer-substring-no-properties (line-beginning-position) (line-end-position)))))

(defun harness-ui-access-test-push (label &optional from)
  "Push the button LABEL, the first after FROM (the buffer's start)."
  (goto-char (or from (point-min)))
  (should (search-forward label nil t))
  (goto-char (match-beginning 0))
  (funcall (get-text-property (point) 'harness-ui-action)))

;;;; Directories

(ert-deftest harness-ui-access-directories-grant-revoke-and-give-up ()
  "The directories list the session's own, follow a grant and its
revocation, and give the working directory up for reading only and back."
  (harness-ui-access-test-with
    (let* ((extra (harness-test-temp-dir))
           (cwd (plist-get (harness-call 'session/get sid) :cwd))
           (tmp (harness-call 'session/tmp-dir sid)))
      (harness-ui-access-test-open sid 'directories)
      (should (derived-mode-p 'harness-ui-access-mode))
      (should (equal (cons 'section 'directories) (get-text-property (point) 'harness-ui-access-anchor)))
      (should (string-match-p "rw +.*working directory" (harness-ui-access-test-row cwd)))
      (should (string-match-p "temporary directory" (harness-ui-access-test-row tmp)))
      (should (string-match-p "\\[Give up\\] \\[Read only\\]" (harness-ui-access-test-row cwd)))
      ;; A grant shows, and its revocation takes it out.
      (harness-ui-access-allow-dir extra)
      (harness-ui-access-test-wait-text "granted to this session")
      (should (member extra (harness-call 'permission/allowed-dirs sid)))
      (harness-ui-access-revoke extra)
      (harness-ui-access-test-wait-text "granted to this session" t)
      (should-not (member extra (harness-call 'permission/allowed-dirs sid)))
      ;; The working directory, for reading only, then back.
      (harness-ui-access-drop-dir cwd t)
      (harness-test-wait (lambda () (string-match-p "\\`  ro .*read only (given up)" (harness-ui-access-test-row cwd)))
                         5 "kept for reading")
      (should (string-match-p "\\[Remove\\] \\[Restore\\]" (harness-ui-access-test-row cwd)))
      (harness-ui-access-restore-dir cwd)
      (harness-test-wait (lambda () (string-match-p "\\`  rw .*working directory" (harness-ui-access-test-row cwd)))
                         5 "given back")
      ;; Given up altogether, it is listed as such, and comes back.
      (harness-ui-access-drop-dir cwd)
      (harness-test-wait (lambda () (string-match-p "\\`  -- .*given up +\\[Restore\\]" (harness-ui-access-test-row cwd)))
                         5 "given up")
      (harness-ui-access-restore-dir cwd)
      (harness-test-wait (lambda () (string-match-p "\\`  rw " (harness-ui-access-test-row cwd))) 5 "back"))))

(ert-deftest harness-ui-access-lists-directories-on-another-host-without-connecting ()
  "A directory on another host is a row like any other: the host's root, the
home directory of the login there (a name with a tilde, which only the host
can expand), a directory in it, one only read.  Drawing the rows, their
buttons' tooltips and what the buttons do ask the host nothing: abbreviating
a tilde name for display would connect, and the view is redrawn at every
change."
  (harness-ui-access-test-with
    (let ((host "/ssh:box.example.invalid:/")
          (home "/ssh:box.example.invalid:~/")
          (sub "/ssh:box.example.invalid:~/projects/x/")
          (notes "/ssh:other.example.invalid:~/notes/"))
      (harness-test-without-connections
        (harness-ui-access-test-open sid 'directories)
        ;; Granted from the view, as the user does: it follows.
        (dolist (dir (list home host sub))
          (harness-ui-access-allow-dir dir)
          (harness-ui-access-test-wait-text (concat (regexp-quote dir) " +granted to this session")))
        (should (string-match-p "\\`  rw +/ssh:box.example.invalid:~/ +granted to this session +\\[Revoke\\] \\[Read only\\]"
                                (harness-ui-access-test-row home)))
        (should (string-match-p "\\`  rw +/ssh:box.example.invalid:/ +granted to this session +\\[Revoke\\]"
                                (harness-ui-access-test-row host)))
        (should (string-match-p "\\`  rw +/ssh:box.example.invalid:~/projects/x/ +granted to this session"
                                (harness-ui-access-test-row sub)))
        ;; The buttons' tooltips name the directory as it is.
        (goto-char (harness-ui-access--find-anchor (cons 'dir home)))
        (let ((revoke (progn (search-forward "[Revoke]") (get-text-property (1- (point)) 'help-echo))))
          (should (string-match-p (concat "Revoke the grant of " (regexp-quote home)) revoke)))
        ;; One only read, from the view, on another host: one inside a home directory granted is writable already.
        (should (string-match-p "already readable and writable"
                                (harness-call 'access/add-read-dir sid "/ssh:box.example.invalid:~/notes/")))
        (harness-ui-access-allow-read-dir notes)
        (harness-ui-access-test-wait-text (concat (regexp-quote notes) " +read only"))
        (should (string-match-p "\\`  ro +/ssh:other.example.invalid:~/notes/ +read only +\\[Remove\\] \\[Make writable\\]"
                                (harness-ui-access-test-row notes)))
        (should (cl-find notes (plist-get (harness-call 'access/describe sid) :dirs)
                         :key (lambda (e) (plist-get e :dir)) :test #'equal))
        ;; Revoked from the view, the row is gone and the message names it as it is.
        (let ((messages nil))
          (cl-letf (((symbol-function 'message)
                     (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) messages)))))
            (harness-ui-access-revoke sub)
            (harness-ui-access-test-wait-text (regexp-quote sub) t)
            (harness-ui-access-remove-read-dir notes)
            (harness-ui-access-test-wait-text (regexp-quote notes) t)
            (harness-test-wait (lambda () (member (concat notes " may no longer be read") messages)) 5 "the message"))
          (should (member (concat "Revoked " sub) messages)))
        (should-not (member sub (harness-call 'permission/allowed-dirs sid)))
        ;; The ones left are drawn still.
        (should (string-match-p "rw +/ssh:box.example.invalid:~/ " (harness-ui-access-test-row home)))))))

(ert-deftest harness-ui-access-follows-grants-made-elsewhere ()
  "A grant made from a prompt, or until the turn ends, redraws the view;
the turn's end takes it out again."
  (harness-ui-access-test-with
    (let ((extra (harness-test-temp-dir))
          (turn (harness-test-temp-dir)))
      (clrhash harness-perms--turn-dirs)
      (harness-ui-access-test-open sid)
      (harness-call 'permission/allow-dir sid extra)
      (harness-ui-access-test-wait-text "granted to this session")
      (harness-perms--grant-for-turn sid turn)
      (harness-ui-access-test-wait-text "granted for this turn")
      (should (string-match-p "\\[Revoke\\]" (harness-ui-access-test-row turn)))
      (harness-emit 'agent/turn-ended sid 'end-turn)
      (harness-ui-access-test-wait-text "granted for this turn" t))))

(ert-deftest harness-ui-access-says-it-is-suspended-until-it-caught-up ()
  "A view no window shows is marked suspended when it misses a change; a click wakes it.
The mark is the one every view that follows the harness only while shown
has (`harness-ui-view-indicator'): it comes with the missed change, goes
when the view is fetched and drawn again, and a click on it does that."
  (harness-ui-access-test-with
    (let* ((extra (harness-test-temp-dir))
           (buffer (harness-ui-access-test-open sid))
           (elsewhere (get-buffer-create " *harness-ui-access-test-elsewhere*")))
      (cl-flet ((mark () (substring-no-properties (with-current-buffer buffer (harness-ui-view-indicator)))))
        (unwind-protect
            (progn
              (should (equal "" (mark)))
              (dolist (w (get-buffer-window-list buffer nil t)) (set-window-buffer w elsewhere))
              (set-window-buffer (selected-window) elsewhere)
              (should-not (get-buffer-window buffer t))
              ;; A grant made elsewhere: the view is left alone, and says so.
              (harness-call 'permission/allow-dir sid extra)
              (harness-test-wait (lambda () (buffer-local-value 'harness-ui-access--stale buffer))
                                 5 "the view to note the grant")
              (should (equal "[Suspended: resume]" (mark)))
              (should-not (with-current-buffer buffer (string-match-p "granted to this session" (harness-ui-access-test-text))))
              ;; A click wakes it: fetched and drawn, the mark gone.
              (set-window-buffer (selected-window) buffer)
              (with-current-buffer buffer (harness-ui-view-wake))
              (should (equal "" (mark)))
              (with-current-buffer buffer (harness-ui-access-test-wait-text "granted to this session")))
          (kill-buffer elsewhere))))))

(ert-deftest harness-ui-access-move-and-keys ()
  "m moves the session, and the view follows; q buries the view; j and d
open it from the harness keys."
  (harness-ui-access-test-with
    (let ((new (harness-test-temp-dir)))
      (harness-ui-access-test-open sid)
      (should (eq #'harness-ui-access-move (key-binding (kbd "m"))))
      (should (eq #'harness-ui-quit-view (key-binding (kbd "q"))))
      (should (eq #'harness-access (lookup-key harness-ui-map (kbd "j"))))
      (should (eq #'harness-directories (lookup-key harness-ui-map (kbd "d"))))
      (harness-ui-access-move new)
      (harness-test-wait (lambda () (equal new (plist-get (harness-call 'session/get sid) :cwd))) 5 "the move")
      (harness-ui-access-test-wait-text (regexp-quote (abbreviate-file-name new))))))

(ert-deftest harness-ui-access-deleted-session ()
  "The view of a deleted session says so, and g fetches nothing more."
  (harness-ui-access-test-with
    (harness-ui-access-test-open sid)
    (harness-call 'session/delete sid)
    (harness-ui-access-test-wait-text "was deleted: it reaches nothing any more")
    (should-not (string-match-p "^Jail" (harness-ui-access-test-text)))
    (harness-ui-access-refresh)
    (should (string-match-p "was deleted" (harness-ui-access-test-text)))))

(ert-deftest harness-ui-access-view-is-no-chat ()
  "The view shows its session without being its chat: the modules that
draw in a session's chat look for it with `harness-ui-chat-of-p', which
passes the view by and finds the chat."
  (harness-ui-access-test-with
    (let ((view (harness-ui-access-test-open sid))
          (chat (harness-chat-buffer sid)))
      (should (equal sid (buffer-local-value 'harness-ui-session-id view)))
      (should-not (harness-ui-chat-of-p view sid))
      (should (harness-ui-chat-of-p chat sid))
      (should-not (harness-ui-chat-of-p chat "another session"))
      ;; A buffer that shows the session and is no other view of it
      ;; counts as its chat, as the tests' stand-ins for a chat do.
      (with-temp-buffer
        (setq-local harness-ui-session-id sid)
        (should (harness-ui-chat-of-p (current-buffer) sid))))))

;;;; The jail

(ert-deftest harness-ui-access-jail-network-writing-and-tools ()
  "The jail shows the sandbox and mode, and its buttons turn the network,
writing and a tool off and on again for the session."
  (harness-ui-access-test-with
    ;; A tool of other kinds of session, as hand_in is a task's.
    (harness-define-tool "test_hand_in" :label "Test hand in" :kind 'meta
                         :description "Hand nothing in." :handler (lambda (_input _ctx) (harness-tool-ok "handed in")))
    (harness-add-filter 'agent/tools (lambda (names _session) (remove "test_hand_in" names)) 50)
    (harness-ui-access-test-open sid)
    (should (string-match-p "sandbox +none" (harness-ui-access-test-text)))
    (should (string-match-p "mode +Ask" (harness-ui-access-test-text)))
    ;; Nobody turned it off: it is named apart, with no button.
    (should (string-match-p "n/a +for other kinds of session: +test_hand_in" (harness-ui-access-test-text)))
    (should-not (string-match-p "off +test_hand_in" (harness-ui-access-test-text)))
    (should (string-match-p "Tools +[0-9]+ offered · 0 off · 1 for other sessions" (harness-ui-access-test-text)))
    (harness-ui-access-test-push "[Turn off]")
    (harness-ui-access-test-wait-text "network +off")
    (should-not (harness-access-network-p (harness-call 'session/get sid)))
    (should (string-match-p "off +test_fetch +no network" (harness-ui-access-test-text)))
    (harness-ui-access-test-push "[Turn on]")
    (harness-ui-access-test-wait-text "network +on")
    (harness-ui-access-test-push "[Make read-only]")
    (harness-ui-access-test-wait-text "writing +read-only")
    (should (harness-readonly-session-p (harness-call 'session/get sid)))
    (harness-ui-access-test-push "[Allow writing]")
    (harness-ui-access-test-wait-text "writing +on")
    (harness-ui-access-set-tool "test_fetch" nil)
    (harness-ui-access-test-wait-text "off +test_fetch +turned off")
    (should (member "test_fetch" (plist-get (harness-access-profile (harness-call 'session/get sid)) :tools-off)))
    (harness-ui-access-toggle-tool "test_fetch")
    (harness-ui-access-test-wait-text "test_fetch +turned off" t)))

;;;; The capabilities of its commands

;; The jail's answer is the test's to give, so the row does not depend on
;; the machine the test runs on: `sandbox/capabilities' is a stand-in
;; (loading the sandbox module would change the `sandbox none' line the
;; test above reads).  The core's own tests, in harness-access-test.el,
;; use the real one.

(defvar harness-ui-access-test--jail nil
  "What the stand-in for `sandbox/capabilities' answers: a plist, as the jail's.")

(defconst harness-ui-access-test--jail-enforcing
  '(:enforced t :backend bwrap
    :grantable ("CAP_SYS_PTRACE" "CAP_NET_RAW" "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE")
    :docs (("CAP_SYS_PTRACE" . "trace and inspect any process in the sandbox (strace, gdb)")
           ("CAP_NET_RAW" . "open raw and packet sockets")
           ("CAP_NET_ADMIN" . "configure the network")
           ("CAP_NET_BIND_SERVICE" . "bind sockets to the ports below 1024"))
    :scopes (("CAP_SYS_PTRACE" . "It reaches the processes of the sandbox's own PID namespace."))
    :why nil)
  "The jail of a bwrap sandbox an ordinary user runs.")

(defun harness-ui-access-test--jail (&rest changes)
  "Return the enforcing jail with CHANGES, a plist, put over it."
  (let ((jail (copy-sequence harness-ui-access-test--jail-enforcing)))
    (cl-loop for (key value) on changes by #'cddr do (setq jail (plist-put jail key value)))
    jail))

(defun harness-ui-access-test--capability-name (value)
  "Return the capability VALUE names among the few the tests use, else nil."
  (let* ((key (upcase (replace-regexp-in-string "-" "_" (string-trim (format "%s" value)))))
         (name (if (string-prefix-p "CAP_" key) key (concat "CAP_" key))))
    (car (member name '("CAP_SYS_PTRACE" "CAP_NET_RAW" "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" "CAP_SYS_ADMIN")))))

(defmacro harness-ui-access-test-with-jail (&rest body)
  "Run BODY as `harness-ui-access-test-with' does, with a stand-in for the jail.
`sandbox/capabilities' answers `harness-ui-access-test--jail', at first
`harness-ui-access-test--jail-enforcing'."
  (declare (indent 0))
  `(harness-ui-access-test-with
     (setq harness-ui-access-test--jail harness-ui-access-test--jail-enforcing)
     (harness-register-method 'sandbox/capabilities (lambda (_cwd) harness-ui-access-test--jail))
     (harness-register-method 'sandbox/capability-name #'harness-ui-access-test--capability-name)
     ,@body))

(defun harness-ui-access-test-flat ()
  "Return the view's text with every run of white space made one space."
  (replace-regexp-in-string "[ \t\n]+" " " (harness-ui-access-test-text)))

(defun harness-ui-access-test-wait-flat (regexp &optional absent)
  "Fetch the view again and wait until its flat text matches REGEXP, or ABSENT."
  (harness-ui-access-refresh)
  (harness-test-wait (lambda ()
                       (let ((found (string-match-p regexp (harness-ui-access-test-flat))))
                         (if absent (not found) found)))
                     5 (format "%s %s" (if absent "no" "a") regexp)))

(defun harness-ui-access-test-capabilities-row ()
  "Return the line of the capabilities row of the view."
  (goto-char (point-min))
  (should (re-search-forward "^  capabilities " nil t))
  (buffer-substring-no-properties (line-beginning-position) (line-end-position)))

(defun harness-ui-access-test-caps (sid)
  "Return the capabilities SID's commands hold."
  (harness-access-capabilities (harness-call 'session/get sid)))

(defmacro harness-ui-access-test-choosing (choice &rest body)
  "Run BODY with `completing-read' answering CHOICE; bind `seen' to what it was asked.
`seen' is (PROMPT COLLECTION REQUIRE-MATCH ANNOTATE), ANNOTATE the
annotation function in `completion-extra-properties'.  A CHOICE that is
a function is called with the collection to choose from it.  It is
nil afterwards when nothing was asked."
  (declare (indent 1))
  `(let ((seen nil))
     (cl-letf (((symbol-function 'completing-read)
                (lambda (prompt collection &optional _predicate require-match &rest _)
                  (setq seen (list prompt collection require-match
                                   (plist-get completion-extra-properties :annotation-function)))
                  (if (functionp ,choice) (funcall ,choice collection) ,choice))))
       ,@body)
     seen))

(ert-deftest harness-ui-access-capabilities-row-draws-none-and-held ()
  "The jail has a capabilities row, after writing: none, and every capability
is dropped, until the session's commands are given some; then it names them,
with the buttons to give more and take them away, and says what they mean."
  (harness-ui-access-test-with-jail
    (harness-ui-access-test-open sid)
    (should (equal "  capabilities none  every capability is dropped  [Give…]"
                   (harness-ui-access-test-capabilities-row)))
    (should-not (string-match-p "\\[Take away…\\]\\|\\[Take all away\\]" (harness-ui-access-test-text)))
    ;; In the jail: after writing, before the directories.
    (goto-char (point-min))
    (let ((writing (progn (re-search-forward "^  writing ") (point)))
          (row (progn (re-search-forward "^  capabilities ") (point)))
          (dirs (progn (re-search-forward "^Directories") (point))))
      (should (< writing row dirs)))
    ;; The tooltips end with the key.
    (goto-char (point-min))
    (search-forward "[Give…]")
    (should (string-match-p "Linux capability, inside the sandbox only (C)\\'"
                            (get-text-property (match-beginning 0) 'help-echo)))
    ;; One given.
    (harness-call 'access/set-capability sid "CAP_SYS_PTRACE" t)
    (harness-ui-access-test-wait-flat "capabilities CAP_SYS_PTRACE")
    (should (equal "  capabilities CAP_SYS_PTRACE  [Give…] [Take away…] [Take all away]"
                   (harness-ui-access-test-capabilities-row)))
    (should (string-match-p "its bash and elisp commands run with these and no other capability, inside the sandbox only"
                            (harness-ui-access-test-flat)))
    (goto-char (point-min))
    (re-search-forward "capabilities \\(CAP_SYS_PTRACE\\)")
    (should (eq 'bold (get-text-property (match-beginning 1) 'face)))
    (dolist (label '("[Take away…]" "[Take all away]"))
      (goto-char (point-min))
      (search-forward label)
      (should (string-match-p "(C\\(?:, all\\)?)\\'" (get-text-property (match-beginning 0) 'help-echo))))
    ;; More, in the order they were given; with all of them given there is nothing to give.
    (harness-call 'access/set-capability sid "CAP_NET_RAW" t)
    (harness-ui-access-test-wait-flat "capabilities CAP_SYS_PTRACE, CAP_NET_RAW")
    (harness-call 'access/set-capability sid "CAP_NET_ADMIN" t)
    (harness-call 'access/set-capability sid "CAP_NET_BIND_SERVICE" t)
    (harness-ui-access-test-wait-flat "CAP_NET_BIND_SERVICE")
    (should (equal "  capabilities CAP_SYS_PTRACE, CAP_NET_RAW, CAP_NET_ADMIN, CAP_NET_BIND_SERVICE  [Take away…] [Take all away]"
                   (harness-ui-access-test-capabilities-row)))
    ;; Taken away elsewhere, the view follows.
    (harness-call 'access/set-capability sid "all" :false)
    (harness-ui-access-test-wait-flat "capabilities none every capability is dropped \\[Give…\\]")
    (should-not (harness-ui-access-test-caps sid))))

(ert-deftest harness-ui-access-capabilities-row-says-why-none-can-be-raised ()
  "When no capability can be given -- the jail cannot, the session is read-only,
the user lets agents ask for none -- the row says why, and offers no [Give…]."
  (harness-ui-access-test-with-jail
    (setq harness-ui-access-test--jail
          (harness-ui-access-test--jail :enforced nil :backend 'systemd
                                        :why "the sandbox backend is systemd-run, not bwrap"))
    (harness-ui-access-test-open sid)
    (should (equal "  capabilities none  every capability is dropped"
                   (string-trim-right (harness-ui-access-test-capabilities-row))))
    (should (string-match-p "capabilities none every capability is dropped cannot be raised: the sandbox backend is systemd-run, not bwrap"
                            (harness-ui-access-test-flat)))
    (should-not (string-match-p "\\[Give…\\]" (harness-ui-access-test-text)))
    ;; Where the jail can, a read-only session still cannot.
    (setq harness-ui-access-test--jail harness-ui-access-test--jail-enforcing)
    (harness-call 'access/set-read-only sid t)
    (harness-ui-access-test-wait-flat "cannot be raised: this session is read-only")
    (should-not (string-match-p "\\[Give…\\]" (harness-ui-access-test-text)))
    (harness-call 'access/set-read-only sid :false)
    (harness-ui-access-test-wait-flat "cannot be raised" t)
    (should (string-match-p "\\[Give…\\]" (harness-ui-access-test-text)))
    ;; Nothing the user lets agents ask for.
    (setq harness-ui-access-test--jail (harness-ui-access-test--jail :grantable nil :docs nil))
    (harness-ui-access-test-wait-flat "cannot be raised: the user lets agents ask for no capability")
    (should-not (string-match-p "\\[Give…\\]" (harness-ui-access-test-text)))))

(ert-deftest harness-ui-access-capabilities-row-says-when-those-held-are-not-passed ()
  "A capability the session's commands hold that the sandbox does not pass on
-- the session is read-only, the jail cannot enforce it, the user no longer
lets agents ask for it -- is named with the reason, and can be taken away."
  (harness-ui-access-test-with-jail
    (harness-call 'access/set-capability sid "CAP_SYS_PTRACE" t)
    (harness-call 'access/set-capability sid "CAP_NET_RAW" t)
    (harness-ui-access-test-open sid)
    (should (string-match-p "capabilities CAP_SYS_PTRACE, CAP_NET_RAW \\[Give…\\] \\[Take away…\\] \\[Take all away\\]"
                            (harness-ui-access-test-flat)))
    ;; Read-only: held, and no [Give…].
    (harness-call 'access/set-read-only sid t)
    (harness-ui-access-test-wait-flat "held, but a read-only session's commands get none")
    (should (equal "  capabilities CAP_SYS_PTRACE, CAP_NET_RAW  [Take away…] [Take all away]"
                   (harness-ui-access-test-capabilities-row)))
    (should-not (string-match-p "its bash and elisp commands run with these" (harness-ui-access-test-flat)))
    (harness-call 'access/set-read-only sid :false)
    (harness-ui-access-test-wait-flat "held, but" t)
    ;; The jail cannot pass them on.
    (setq harness-ui-access-test--jail
          (harness-ui-access-test--jail :enforced nil :backend 'systemd
                                        :why "the sandbox backend is systemd-run, not bwrap"))
    (harness-ui-access-test-wait-flat "held, but not passed: the sandbox backend is systemd-run, not bwrap")
    (should (equal "  capabilities CAP_SYS_PTRACE, CAP_NET_RAW  [Take away…] [Take all away]"
                   (harness-ui-access-test-capabilities-row)))
    ;; One the user no longer lets agents ask for.
    (setq harness-ui-access-test--jail (harness-ui-access-test--jail :grantable '("CAP_NET_RAW")))
    (harness-ui-access-test-wait-flat "CAP_SYS_PTRACE held, but not passed: the user no longer lets agents ask for it")
    (should (equal "  capabilities CAP_SYS_PTRACE, CAP_NET_RAW  [Take away…] [Take all away]"
                   (harness-ui-access-test-capabilities-row)))
    (should (equal '("CAP_SYS_PTRACE" "CAP_NET_RAW") (harness-ui-access-test-caps sid)))))

(ert-deftest harness-ui-access-capabilities-buttons-change-the-profile ()
  "[Give…] asks which of those an agent may ask for the commands do not hold,
each with what it lets them do; [Take away…] which of those held; [Take all
away] asks nothing; each changes the session at once and the view follows."
  (harness-ui-access-test-with-jail
    (harness-ui-access-test-open sid)
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) messages)))))
        ;; Give one: the prompt names the four, each annotated, and a name is required.
        (let ((seen (harness-ui-access-test-choosing "CAP_NET_RAW"
                      (harness-ui-access-test-push "[Give…]")
                      (harness-ui-access-test-wait-flat "capabilities CAP_NET_RAW"))))
          (should (equal "Give the session's commands: " (nth 0 seen)))
          (should (equal '("CAP_SYS_PTRACE" "CAP_NET_RAW" "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE") (nth 1 seen)))
          (should (nth 2 seen))
          (should (equal "  open raw and packet sockets" (funcall (nth 3 seen) "CAP_NET_RAW")))
          (should (string-match-p "strace" (funcall (nth 3 seen) "CAP_SYS_PTRACE")))
          (should (equal "" (funcall (nth 3 seen) "CAP_UNKNOWN"))))
        (should (equal '("CAP_NET_RAW") (harness-ui-access-test-caps sid)))
        (harness-test-wait (lambda () (member "CAP_NET_RAW given to the session's commands" messages)) 5 "the message")
        ;; Give another: the one held is not offered again.
        (let ((seen (harness-ui-access-test-choosing "CAP_SYS_PTRACE"
                      (harness-ui-access-test-push "[Give…]")
                      (harness-ui-access-test-wait-flat "capabilities CAP_NET_RAW, CAP_SYS_PTRACE"))))
          (should (equal '("CAP_SYS_PTRACE" "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE") (nth 1 seen))))
        (should (equal '("CAP_NET_RAW" "CAP_SYS_PTRACE") (harness-ui-access-test-caps sid)))
        ;; Take one away: the prompt offers those held.
        (let ((seen (harness-ui-access-test-choosing "CAP_NET_RAW"
                      (harness-ui-access-test-push "[Take away…]")
                      (harness-ui-access-test-wait-flat "capabilities CAP_SYS_PTRACE \\["))))
          (should (equal "Take away: " (nth 0 seen)))
          (should (equal '("CAP_NET_RAW" "CAP_SYS_PTRACE") (nth 1 seen)))
          (should (nth 2 seen))
          (should (equal "  open raw and packet sockets" (funcall (nth 3 seen) "CAP_NET_RAW"))))
        (should (equal '("CAP_SYS_PTRACE") (harness-ui-access-test-caps sid)))
        (harness-test-wait (lambda () (member "CAP_NET_RAW taken away from the session's commands" messages)) 5 "the message")
        ;; Take all away: nothing is asked.
        (harness-call 'access/set-capability sid "CAP_NET_ADMIN" t)
        (harness-ui-access-test-wait-flat "capabilities CAP_SYS_PTRACE, CAP_NET_ADMIN")
        (let ((seen (harness-ui-access-test-choosing (lambda (_) (error "Nothing may be asked"))
                      (harness-ui-access-test-push "[Take all away]")
                      (harness-ui-access-test-wait-flat "capabilities none"))))
          (should-not seen))
        (should-not (harness-ui-access-test-caps sid))
        (harness-test-wait (lambda () (member "No capability left for the session's commands" messages)) 5 "the message")))
    ;; The transcript says who changed it.
    (let ((hints (delq nil (mapcar (lambda (n) (and (eq (plist-get n :kind) 'hint) (plist-get n :content)))
                                   (harness-call 'session/nodes sid)))))
      (should (cl-some (lambda (h) (string-match-p "CAP_NET_RAW given to the session's commands (set by the user)" h)) hints))
      (should (cl-some (lambda (h) (string-match-p "CAP_NET_RAW taken away from the session's commands (set by the user)" h)) hints))
      (should (cl-some (lambda (h) (string-match-p "no capability left for the session's commands (set by the user)" h)) hints)))))

(ert-deftest harness-ui-access-capabilities-key-and-menu ()
  "C gives the session's commands a capability or takes one away, choosing
among those held (marked), and those an agent may ask for; the harness menu
lists it; it says why when nothing can be given and nothing is held."
  (harness-ui-access-test-with-jail
    (harness-ui-access-test-open sid)
    (should (eq #'harness-ui-access-toggle-capability (key-binding (kbd "C"))))
    (should (cl-some (lambda (entry) (and (listp entry) (equal (nth 0 entry) ". C")
                                          (eq (nth 2 entry) #'harness-ui-access-toggle-capability)))
                     (cl-loop for group in (cdr (get 'harness-ui-access-mode 'harness-menu-group))
                              append (append (cdr (append group nil)) nil))))
    ;; Called from Lisp, it gives, then takes away.
    (harness-ui-access-toggle-capability "CAP_SYS_PTRACE")
    (harness-ui-access-test-wait-flat "capabilities CAP_SYS_PTRACE")
    (harness-ui-access-toggle-capability "CAP_SYS_PTRACE")
    (harness-ui-access-test-wait-flat "capabilities none")
    ;; At the keyboard it chooses: the held ones are marked, all is offered with them.
    (let ((seen (harness-ui-access-test-choosing "CAP_NET_RAW"
                  (call-interactively #'harness-ui-access-toggle-capability)
                  (harness-ui-access-test-wait-flat "capabilities CAP_NET_RAW"))))
      (should (equal "Give or take away: " (nth 0 seen)))
      (should (equal '("CAP_SYS_PTRACE" "CAP_NET_RAW" "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE") (nth 1 seen))))
    (let ((seen (harness-ui-access-test-choosing "CAP_SYS_PTRACE"
                  (call-interactively #'harness-ui-access-toggle-capability)
                  (harness-ui-access-test-wait-flat "capabilities CAP_NET_RAW, CAP_SYS_PTRACE"))))
      (should (equal '("CAP_NET_RAW (held)" "CAP_SYS_PTRACE" "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE"
                       "all (take every one away)")
                     (nth 1 seen)))
      (should (equal "  open raw and packet sockets" (funcall (nth 3 seen) "CAP_NET_RAW (held)")))
      (should (equal "" (funcall (nth 3 seen) "all (take every one away)"))))
    ;; A held one is taken away.
    (harness-ui-access-test-choosing "CAP_NET_RAW (held)"
      (call-interactively #'harness-ui-access-toggle-capability)
      (harness-ui-access-test-wait-flat "capabilities CAP_SYS_PTRACE \\["))
    (should (equal '("CAP_SYS_PTRACE") (harness-ui-access-test-caps sid)))
    (harness-ui-access-test-choosing "all (take every one away)"
      (call-interactively #'harness-ui-access-toggle-capability)
      (harness-ui-access-test-wait-flat "capabilities none"))
    (should-not (harness-ui-access-test-caps sid))
    ;; The commands of the row, asked at the keyboard.
    (let ((err (progn (setq harness-ui-access-test--jail
                            (harness-ui-access-test--jail :enforced nil :why "the sandbox backend is systemd-run"))
                      (harness-ui-access-refresh)
                      (harness-ui-access-test-wait-flat "cannot be raised")
                      (should-error (call-interactively #'harness-ui-access-toggle-capability) :type 'user-error))))
      (should (string-match-p "No capability can be given now: the sandbox backend is systemd-run" (cadr err))))
    (should-error (call-interactively #'harness-ui-access-grant-capability) :type 'user-error)
    (let ((err (should-error (call-interactively #'harness-ui-access-revoke-capability) :type 'user-error)))
      (should (string-match-p "hold no capability" (cadr err))))
    ;; Everything given: nothing left to give.
    (setq harness-ui-access-test--jail harness-ui-access-test--jail-enforcing)
    (dolist (name '("CAP_SYS_PTRACE" "CAP_NET_RAW" "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE"))
      (harness-call 'access/set-capability sid name t))
    (harness-ui-access-test-wait-flat "CAP_NET_BIND_SERVICE")
    (let ((err (should-error (call-interactively #'harness-ui-access-grant-capability) :type 'user-error)))
      (should (string-match-p "given already" (cadr err))))))

(ert-deftest harness-ui-access-capabilities-refusal-is-reported ()
  "A capability the jail would not pass on is refused by the harness, and the
echo area says why; the session is left as it was."
  (harness-ui-access-test-with-jail
    (setq harness-ui-access-test--jail
          (harness-ui-access-test--jail :enforced nil :backend 'systemd
                                        :why "the sandbox backend is systemd-run, not bwrap"))
    (harness-ui-access-test-open sid)
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) messages)))))
        (harness-ui-access-set-capability "CAP_NET_RAW" t)
        (harness-test-wait (lambda () (cl-some (lambda (m) (string-match-p "access/set-capability failed: .*the sandbox cannot give this session's commands a capability: the sandbox backend is systemd-run" m))
                                               messages))
                           5 "the refusal"))
      (should-not (harness-ui-access-test-caps sid)))))

(ert-deftest harness-ui-access-capabilities-row-needs-nothing-from-an-older-harness ()
  "A harness that does not describe capabilities has no row, and drawing the
view signals nothing; the commands say so."
  (harness-ui-access-test-with-jail
    (harness-ui-access-test-open sid)
    (should (string-match-p "^  capabilities " (harness-ui-access-test-text)))
    (dolist (capabilities '(:absent nil))
      (setq harness-ui-access--describe
            (if (eq capabilities :absent)
                (harness-plist-remove harness-ui-access--describe :capabilities)
              (plist-put (copy-sequence harness-ui-access--describe) :capabilities nil)))
      (harness-ui-access--render)
      (should-not (string-match-p "capabilities" (harness-ui-access-test-text)))
      (should (string-match-p "^  writing +on" (harness-ui-access-test-text)))
      (should (string-match-p "^Directories" (harness-ui-access-test-text)))
      (let ((err (should-error (call-interactively #'harness-ui-access-toggle-capability) :type 'user-error)))
        (should (string-match-p "does not say what capabilities" (cadr err)))))
    ;; The row comes back with the next fetch.
    (harness-ui-access-refresh)
    (harness-test-wait (lambda () (string-match-p "^  capabilities " (harness-ui-access-test-text))) 5 "the row")))

;;;; Rules

(ert-deftest harness-ui-access-rules-say-which-host-they-hold-for ()
  "A rule for one host reads as one: the lasting answer to an ssh call holds
for the host that call named (and the programs it ran), and a line that left
the host out would read as an answer for every host.  A rule that pins other
arguments says so too, a long one cut to a line, and one without arguments
reads as it did."
  (let ((host "admin@laptop-0:4358"))
    (should (equal "allow ssh: journalctl, tail whose host is exactly \"admin@laptop-0:4358\""
                   (substring-no-properties
                    (harness-ui-access--rule-text
                     (list :tool "ssh" :input (list :host host) :commands '(("journalctl") ("tail")) :behavior "allow")))))
    (should (equal "allow ssh whose host is exactly \"admin@laptop-0:4358\""
                   (substring-no-properties
                    (harness-ui-access--rule-text (list :tool "ssh" :input (list :host host) :behavior "allow")))))
    (should (equal "deny ssh whose host is exactly \"benito\" and command is exactly \"ls -la\""
                   (substring-no-properties
                    (harness-ui-access--rule-text
                     (list :tool "ssh" :input '(:host "benito" :command "ls -la") :behavior "deny")))))
    (should (string-match-p "\\`allow bash whose command is exactly \"[^\"]\\{49\\}…\"\\'"
                            (substring-no-properties
                             (harness-ui-access--rule-text
                              (list :tool "bash" :input (list :command (make-string 80 ?x)) :behavior "allow")))))
    ;; A rule about a host's file system, and the ones that never had arguments.
    (should (equal "allow bash: ls, cat in /ssh:u@box:/**"
                   (substring-no-properties
                    (harness-ui-access--rule-text
                     (list :tool "bash" :commands '(("ls") ("cat")) :path "/ssh:u@box:/**" :behavior "allow")))))
    (should (equal "allow ssh: journalctl, tail"
                   (substring-no-properties
                    (harness-ui-access--rule-text
                     (list :tool "ssh" :commands '(("journalctl") ("tail")) :behavior "allow")))))
    ;; An argument list nobody could have written is not shown as one.
    (should (equal "allow ssh" (substring-no-properties
                                (harness-ui-access--rule-text (list :tool "ssh" :input "host" :behavior "allow")))))))

(ert-deftest harness-ui-access-draws-the-rules-of-a-host ()
  "The rules section lists the answers of this session and the lasting ones,
each for the host it holds for, drawn from what the harness describes."
  (harness-ui-access-test-with
    (let ((harness-perms-rules (list (list :tool "ssh" :input '(:host "benito") :commands '(("uptime")) :behavior 'allow)))
          (rule '(:tool "ssh" :input (:host "admin@laptop-0:4358") :commands (("journalctl") ("tail")) :behavior allow)))
      (puthash sid (list rule) harness-perms--session-rules)
      (harness-ui-access-test-open sid 'rules)
      (harness-ui-access-test-wait-text
       "this session +allow ssh: journalctl, tail whose host is exactly \"admin@laptop-0:4358\"")
      (should (string-match-p "every session +allow ssh: uptime whose host is exactly \"benito\""
                              (harness-ui-access-test-text))))))

;;;; Judgements

(ert-deftest harness-ui-access-judgements-are-the-chats-blocks ()
  "Each judged call is drawn as the chat draws it, under what was decided,
by whom and its handle; a denied one offers [Approve], which approves it;
the filter narrows the list; TAB unfolds a call."
  (harness-ui-access-test-with
    (let ((harness-provider-demo-script-override
           '((:type tool-call :id "j1" :name "drop_access" :input (:attribute "network"))
             (:type tool-call :id "j2" :name "test_fetch" :input (:url "https://example.com"))
             (:type text :delta "Done.")
             (:type done :stop-reason end-turn))))
      (harness-test-await (harness-call 'agent/prompt sid "go") 20)
      (harness-test-wait (lambda () (eq 'idle (plist-get (harness-call 'session/get sid) :status))) 10 "idle")
      ;; The approval below tells the agent to rerun the call: its turn
      ;; only answers.
      (setq harness-provider-demo-script-override
            '((:type text :delta "Noted.") (:type done :stop-reason end-turn)))
      (harness-ui-access-test-open sid 'judgements)
      (harness-ui-access-test-wait-text "handle j2")
      (let ((text (harness-ui-access-test-text)))
        (should (string-match-p "✗ denied by the access settings · handle j2" text))
        (should (string-match-p "this session may not reach the network" text))
        (should (string-match-p "✓ allowed by the access settings · handle j1" text))
        (should (string-match-p "Test fetch:? https://example.com" text))
        (should (string-match-p "\\[Approve\\]" text)))
      ;; The call is a chat block: it folds and unfolds.
      (goto-char (harness-ui-access--find-anchor '(call . "j2")))
      (should (search-forward "Test fetch" nil t))
      (let ((block (gethash (get-text-property (point) 'harness-chat-node) harness-chat--blocks)))
        (should block)
        (should (harness-chat-block-collapsed block))
        (harness-ui-access-toggle)
        (should-not (harness-chat-block-collapsed block)))
      ;; [Approve] approves the denied call, and the view says so.
      (goto-char (point-min))
      (should (search-forward "[Approve]" nil t))
      (goto-char (match-beginning 0))
      (funcall (get-text-property (point) 'harness-chat-action))
      (harness-ui-access-test-wait-text "user-approved")
      ;; The block stays unfolded across the redraw.
      (goto-char (harness-ui-access--find-anchor '(call . "j2")))
      (should (search-forward "Test fetch" nil t))
      (should-not (harness-chat-block-collapsed
                   (gethash (get-text-property (point) 'harness-chat-node) harness-chat--blocks)))
      ;; The filter.
      (harness-ui-access-filter-behavior "deny")
      (harness-ui-access-test-wait-text "handle j1" t)
      (should (string-match-p "handle j2" (harness-ui-access-test-text)))
      (harness-ui-access-filter-clear)
      (harness-ui-access-test-wait-text "handle j1")
      (harness-ui-access-filter-text "may not reach")
      (harness-ui-access-test-wait-text "handle j1" t)
      (should (string-match-p "\\[text: may not reach\\]" (harness-ui-access-test-text))))))

(ert-deftest harness-ui-access-waiting-requests-are-the-pending-panels ()
  "A request the session waits on shows as the chat's panel, without the
compose box's hint, and its call among the judgements as waiting; the
panel answers it."
  (harness-ui-access-test-with
    (let* ((harness-provider-demo-script-override
            '((:type tool-call :id "w1" :name "test_fetch" :input (:url "https://example.com"))
              (:type done :stop-reason end-turn)))
           (turn (harness-call 'agent/prompt sid "go")))
      (harness-test-wait (lambda () (harness-call 'permission/pending sid)) 5 "the request")
      (harness-ui-access-test-open sid)
      (harness-ui-access-test-wait-text "Waiting for you")
      (let ((text (harness-ui-access-test-text)))
        (should (string-match-p "Permission +Test fetch" text))
        (should (string-match-p "? waiting for you · handle w1" text))
        (should-not (string-match-p "from the box" text)))
      (harness-ui-access-test-push "[Allow]" (harness-ui-access--find-anchor '(call . "w1")))
      (harness-test-await turn 20)
      (harness-ui-access-test-wait-text "Waiting for you" t)
      (harness-ui-access-test-wait-text "✓ allowed by you · handle w1"))))

(provide 'harness-ui-access-test)
;;; harness-ui-access-test.el ends here
