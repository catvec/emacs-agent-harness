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
