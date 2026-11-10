;;; harness-ui-access-test.el --- Tests for the access view of a session  -*- lexical-binding: t; -*-

;;; Commentary:

;; The access view (harness-ui-access.el) against the real state layer,
;; the permission chain, the access module, the demo provider and the
;; in-process ACP connection: its pages (the Overview, Tools, Rules and
;; Judgements), its directories follow grants made anywhere, its
;; settings change the session's access, and its judgements are the
;; chat's own tool-call blocks, [Approve] included.  The permission
;; mode in a chat's header line opens it.  Every button is pushed as a
;; click does, which calls its action with no arguments.

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
(defvar harness-ui-access--filter)
(defvar harness-ui-access--page)
(defvar harness-ui-map)
(defvar harness-perms-summarize)
(defvar harness-chat--loading)
(defvar harness-compose-end)
(defvar harness-chat--settings-marker)
(defvar harness-chat--settings-end)
(declare-function harness-provider-demo--script "harness-provider-demo")
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-chat-push "harness-ui-chat")

(defconst harness-ui-access-test-width 120
  "The width of the window the views are laid out for in the tests.
No window shows a view in a batch Emacs, and the one a test gets is as
narrow as the batch frame, which would cut what the tests read.")

(defmacro harness-ui-access-test-with (&rest body)
  "Load the harness, the access module and the UI with the access view, run BODY.
SID names a fresh session in ask mode.  The views are laid out for a
window `harness-ui-access-test-width' columns wide."
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
       (cl-letf (((symbol-function 'harness-ui-access--width) (lambda () harness-ui-access-test-width)))
         (unwind-protect
             (progn ,@body)
           (dolist (b (buffer-list))
             (when (with-current-buffer b (derived-mode-p 'harness-ui-access-mode)) (kill-buffer b)))
           (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) harness-chat--buffers)
           (clrhash harness-chat--buffers)
           (dolist (c (copy-sequence harness-acp--clients))
             (harness-acp--drop-client c)))))))

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

(defun harness-ui-access-test-flat-string (string)
  "Return STRING with every run of white space one space, and the radio buttons as text.
A choice in effect reads (x), one that is not ( ), whatever the display
draws the rings with."
  (string-trim
   (replace-regexp-in-string
    "\\(?:○\\|( )\\)" "( )"
    (replace-regexp-in-string
     "\\(?:◉\\|(\\*)\\)" "(x)"
     (replace-regexp-in-string "[ \t\n]+" " " string)))))

(defun harness-ui-access-test-setting (name)
  "Return the text of the row of setting NAME, a symbol, and its note, flat.
Where it reads \"Network (x) On ( ) Off\", the choice in effect is
marked (x) (`harness-ui-access-test-flat-string')."
  (let ((start (harness-ui-access--find-anchor (cons 'setting name))))
    (should start)
    (harness-ui-access-test-flat-string
     (buffer-substring-no-properties
      start (or (next-single-property-change start 'harness-ui-access-anchor) (point-max))))))

(defun harness-ui-access-test-wait-setting (name regexp)
  "Wait until the row of setting NAME matches REGEXP, flat."
  (harness-test-wait (lambda ()
                       (and (harness-ui-access--find-anchor (cons 'setting name))
                            (string-match-p regexp (harness-ui-access-test-setting name))))
                     5 (format "%s to read %s" name regexp)))

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
        (should (string-match-p "\\`  rw +/ssh:box.example.invalid:~/ +granted to this session +\\[Revocation\\] \\[Read only\\]"
                                (harness-ui-access-test-row home)))
        (should (string-match-p "\\`  rw +/ssh:box.example.invalid:/ +granted to this session +\\[Revocation\\]"
                                (harness-ui-access-test-row host)))
        (should (string-match-p "\\`  rw +/ssh:box.example.invalid:~/projects/x/ +granted to this session"
                                (harness-ui-access-test-row sub)))
        ;; The buttons' tooltips name the directory as it is.
        (goto-char (harness-ui-access--find-anchor (cons 'dir home)))
        (let ((revoke (progn (search-forward "[Revocation]") (get-text-property (1- (point)) 'help-echo))))
          (should (string-match-p (concat "grant revocation · " (regexp-quote home)) revoke)))
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
            (harness-test-wait (lambda () (member (concat "Read access removed: " notes) messages)) 5 "the message"))
          (should (member (concat "Revocation · " sub) messages)))
        (should-not (member sub (harness-call 'permission/allowed-dirs sid)))
        ;; The ones left are drawn still.
        (should (string-match-p "rw +/ssh:box.example.invalid:~/ " (harness-ui-access-test-row home)))))))

(ert-deftest harness-ui-access-directories-list-the-worktree-of-a-sub-agent ()
  "The worktree of a sub-agent is a row of its own: read only, named by what it
is, with [Remove] and [Make writable].  [Make writable] grants it beside the
read grant, [Remove] takes it away, and the grant ending takes the row."
  (harness-ui-access-test-with
    (let* ((base (file-name-as-directory (file-truename (harness-test-temp-dir))))
           (worktree (file-name-as-directory (expand-file-name "repo/.worktrees/harness-kid" base))))
      (make-directory worktree t)
      (harness-ui-access-test-open sid 'directories)
      (harness-call 'access/grant-child-worktree sid "kid" worktree)
      (harness-ui-access-test-wait-text (concat (regexp-quote (abbreviate-file-name worktree)) " +sub-agent worktree"))
      (should (string-match-p "\\`  ro +.* +sub-agent worktree +\\[Remove\\] \\[Make writable\\]"
                              (harness-ui-access-test-row worktree)))
      ;; Made writable: a grant of the session, which beats the read-only entry.
      (harness-ui-access-test-click "[Make writable]" (harness-ui-access--find-anchor (cons 'dir worktree)))
      (harness-ui-access-test-wait-text "rw +.* +granted to this session")
      (should (eq 'session (plist-get (cl-find worktree (harness-call 'permission/dirs sid)
                                               :key (lambda (e) (plist-get e :dir)) :test #'equal)
                                      :source)))
      ;; The grant revoked, the sub-agent's read-only entry shows again.
      (harness-call 'permission/revoke-dir sid worktree)
      (harness-ui-access-test-wait-text "ro +.* +sub-agent worktree")
      ;; Removed from the view, the row is gone.
      (harness-ui-access-test-click "[Remove]" (harness-ui-access--find-anchor (cons 'dir worktree)))
      (harness-ui-access-test-wait-text "sub-agent worktree" t)
      (should-not (cl-find worktree (harness-call 'permission/dirs sid)
                           :key (lambda (e) (plist-get e :dir)) :test #'equal)))))

(defun harness-ui-access-test-click (label &optional from)
  "Click the button LABEL, the first after FROM (the buffer's start), as a user does.
A click runs the button's action with no arguments (`harness-ui-action-push'),
which is what these buttons must survive: pushing the button's action by
hand, with the arguments a test happens to know, hid that two of them
took some."
  (goto-char (or from (point-min)))
  (should (search-forward label nil t))
  (goto-char (match-beginning 0))
  (harness-ui-action-push))

(ert-deftest harness-ui-access-directory-buttons-work-when-clicked ()
  "[Allow a directory…], [Allow reading a directory…] and [Move the session…]
ask for the directory and do what they say.  Each runs a command that needs
the directory, and a click gives its action no arguments: they signalled
wrong-number-of-arguments, and nothing was asked or done."
  (harness-ui-access-test-with
    (let ((write (harness-test-temp-dir))
          (read-only (harness-test-temp-dir))
          (new (harness-test-temp-dir))
          (asked nil)
          (answer nil))
      (harness-ui-access-test-open sid)
      (cl-letf (((symbol-function 'read-directory-name)
                 (lambda (prompt &rest _) (push prompt asked) answer)))
        ;; Granted for writing, to this session.
        (setq answer write)
        (harness-ui-access-test-click "[Allow a directory…]")
        (should (equal '("This session: ") asked))
        (harness-ui-access-test-wait-text "granted to this session")
        (should (member write (harness-call 'permission/allowed-dirs sid)))
        (should (string-match-p "\\`  rw " (harness-ui-access-test-row write)))
        ;; Read only.
        (setq answer read-only)
        (harness-ui-access-test-click "[Allow reading a directory…]")
        (should (equal "Reading: " (car asked)))
        (harness-test-wait (lambda ()
                             (and (harness-ui-access--find-anchor (cons 'dir read-only))
                                  (string-match-p "\\`  ro +.* +read only"
                                                  (harness-ui-access-test-row read-only))))
                           5 "the directory read only")
        (should-not (member read-only (harness-call 'permission/allowed-dirs sid)))
        ;; The session moves to another working directory.
        (setq answer new)
        (harness-ui-access-test-click "[Move the session…]")
        (should (string-match-p "\\`Move .* to directory: \\'" (car asked)))
        (harness-test-wait (lambda () (equal new (plist-get (harness-call 'session/get sid) :cwd)))
                           5 "the move")))))

(ert-deftest harness-ui-access-undo-a-decision-button-works-when-clicked ()
  "[Undo a decision…], on the Rules page, runs `harness-decision-undo', which
asks which decision, as its key does: a click gives its action no arguments,
and the command needs the decision it is to undo."
  (harness-ui-access-test-with
    (let ((undone nil))
      (cl-letf (((symbol-function 'harness-decision-undo)
                 (lambda (id) (interactive (list "decision-1")) (push id undone))))
        (harness-ui-access-test-open sid 'rules)
        (harness-ui-access-test-click "[Undo a decision…]")
        (should (equal '("decision-1") undone))))))

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
      (should (string-match-p "\\[Revocation\\]" (harness-ui-access-test-row turn)))
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
  "m moves the session, and the view follows; 1 to 4 show its pages and q
leaves the Overview as any view is left; C-c h S j and C-c h S d open it
from the harness's keys."
  (harness-ui-access-test-with
    (let ((new (harness-test-temp-dir)))
      (harness-ui-access-test-open sid)
      (should (eq #'harness-ui-access-move (key-binding (kbd "m"))))
      (should (eq #'harness-ui-access-quit (key-binding (kbd "q"))))
      (should (equal '(harness-ui-access-show-overview harness-ui-access-show-tools
                       harness-ui-access-show-rules harness-ui-access-show-judgements)
                     (mapcar (lambda (key) (key-binding (kbd key))) '("1" "2" "3" "4"))))
      (should (eq #'harness-access (lookup-key harness-ui-session-map (kbd "j"))))
      (should (eq #'harness-directories (lookup-key harness-ui-session-map (kbd "d"))))
      (should (eq #'harness-access (key-binding (kbd "C-c h S j"))))
      (should (eq #'harness-directories (key-binding (kbd "C-c h S d"))))
      (harness-ui-access-move new)
      (harness-test-wait (lambda () (equal new (plist-get (harness-call 'session/get sid) :cwd))) 5 "the move")
      (harness-ui-access-test-wait-text (regexp-quote (abbreviate-file-name new))))))

(ert-deftest harness-ui-access-deleted-session ()
  "The view of a deleted session says so, and g fetches nothing more."
  (harness-ui-access-test-with
    (harness-ui-access-test-open sid)
    (harness-call 'session/delete sid)
    (harness-ui-access-test-wait-text "^Session .* deleted$")
    (should-not (string-match-p "Settings\\|Directories" (harness-ui-access-test-text)))
    (harness-ui-access-refresh)
    (should (string-match-p "^Session .* deleted$" (harness-ui-access-test-text)))))

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

;;;; The settings

(ert-deftest harness-ui-access-overview-groups-the-settings ()
  "The Overview leads with the settings, in one group: the permission mode,
whether the session asks you, the network, writing and the sandbox, each the
choices it has with the one in effect marked.  The directories follow, and then
a line each for the tools, the rules and the judgements, which have pages of
their own: none of their lists is on the Overview."
  (harness-ui-access-test-with
    (harness-ui-access-test-open sid)
    (let ((text (harness-ui-access-test-text)))
      (should (string-match-p "\\`Jail & permissions of " text))
      (should (string-match-p "^Overview  ·  Tools  ·  Rules  ·  Judgements  ·  Secrets$" text)))
    (should (equal "Permission mode (x) Ask ( ) Accept Edits ( ) Auto ( ) YOLO Writes, commands, network · ask"
                   (harness-ui-access-test-setting 'mode)))
    (should (equal "Interaction (x) Interactive ( ) Non-interactive prompts · undecided calls"
                   (harness-ui-access-test-setting 'interaction)))
    (should (equal "Network (x) On ( ) Off" (harness-ui-access-test-setting 'network)))
    (should (equal "Writing (x) On ( ) Read-only" (harness-ui-access-test-setting 'writing)))
    (should (string-match-p "\\`Sandbox none No sandbox module · commands unconfined"
                            (harness-ui-access-test-setting 'sandbox)))
    ;; In one group, then the directories, then the details.
    (let ((settings (harness-ui-access--find-anchor '(section . settings)))
          (mode (harness-ui-access--find-anchor '(setting . mode)))
          (sandbox (harness-ui-access--find-anchor '(setting . sandbox)))
          (dirs (harness-ui-access--find-anchor '(section . directories)))
          (details (harness-ui-access--find-anchor '(section . details))))
      (should (< settings mode sandbox dirs details)))
    ;; What has a page of its own is summed up in a line, not listed.
    (should (string-match-p "^  Tools +[0-9]+ offered · 0 off$" (harness-ui-access-test-text)))
    (should (string-match-p "^  Rules +none (permission mode only) · [0-9]+ tools exempt from prompts$"
                            (harness-ui-access-test-text)))
    (should (string-match-p "^  Judgements +none yet$" (harness-ui-access-test-text)))
    (let ((case-fold-search nil))
      (should-not (string-match-p "ask_user\\|read_file\\|Never ask\\|Offered" (harness-ui-access-test-text)))
      (should-not (string-match-p "\\[All\\]\\|decided by" (harness-ui-access-test-text))))))

(ert-deftest harness-ui-access-sandbox-row-says-what-the-backend-cannot-do ()
  "The Sandbox row names the backend in use, what it cannot do of the access model,
and, when OpenShell was asked for and could not be used, which backend that is and why."
  (harness-ui-access-test-with
    ;; OpenShell in use: its limits, a line each.
    (harness-register-method
     'sandbox/status
     (lambda () '(:backend openshell :available (openshell) :policy preferred
                  :limits ("No Linux capability can be given: OpenShell runs commands as a non-root user."
                           "The network is never open: a command with it on reaches only github.com:443."))))
    (harness-ui-access-test-open sid)
    (let ((row (harness-ui-access-test-setting 'sandbox)))
      (should (string-match-p "\\`Sandbox openshell " row))
      (should (string-match-p "Limit · No Linux capability can be given: OpenShell runs commands as a non-root user\\." row))
      (should (string-match-p "Limit · The network is never open: a command with it on reaches only github\\.com:443\\." row))
      (should-not (string-match-p "asked for" row)))
    ;; Asked for and unusable: what runs instead, and the reason.
    (harness-register-method
     'sandbox/status
     (lambda () '(:backend bwrap :available (bwrap openshell) :policy preferred :limits nil
                  :requested openshell
                  :problem "the gateway fake does not answer: connection refused")))
    (harness-ui-access-refresh)
    (harness-ui-access-test-wait-text "OpenShell asked for, not used")
    (let ((row (harness-ui-access-test-setting 'sandbox)))
      (should (string-match-p "\\`Sandbox bwrap OpenShell asked for, not used" row))
      (should (string-match-p "OpenShell cannot be used: the gateway fake does not answer: connection refused" row))
      (should-not (string-match-p "Limit" row)))
    ;; A harness that says neither is read as before: no OpenShell, no buttons for it.
    (harness-register-method 'sandbox/status (lambda () '(:backend bwrap :available (bwrap) :policy preferred)))
    (harness-ui-access-refresh)
    (harness-ui-access-test-wait-text "OpenShell asked for, not used" t)
    (should-not (string-match-p "Limit\\|cannot be used\\|Detect again\\|Test OpenShell"
                                (harness-ui-access-test-setting 'sandbox)))))

(ert-deftest harness-ui-access-sandbox-buttons-detect-again-and-test-openshell ()
  "Where OpenShell is installed or was asked for, the Sandbox row has [Detect again],
which asks the harness to look for the backends again, and [Test OpenShell], which
starts a throwaway sandbox; each says what came of it, and the view follows."
  (harness-ui-access-test-with
    (let ((status '(:backend bwrap :available (bwrap openshell) :policy preferred
                    :requested openshell :problem "the gateway does not answer"))
          (checks 0)
          (messages nil))
      (harness-register-method 'sandbox/status (lambda () status))
      ;; The gateway is up by the time the harness looks again.
      (harness-register-method 'sandbox/detect
                               (lambda ()
                                 (setq status '(:backend openshell :available (bwrap openshell) :policy preferred
                                                :limits ("No Linux capability can be given.")))
                                 status))
      (harness-register-method 'sandbox/check
                               (lambda ()
                                 (cl-incf checks)
                                 (harness-resolved (list :ok t :message "OpenShell started a sandbox and ran a command in it"))))
      (harness-ui-access-test-open sid)
      (should (equal "[Detect again] [Test OpenShell]"
                     (let ((row (harness-ui-access-test-setting 'sandbox)))
                       (and (string-match "\\[Detect again\\] \\[Test OpenShell\\]" row) (match-string 0 row)))))
      (should (eq #'harness-ui-access-redetect-sandbox (key-binding (kbd "D"))))
      (should (eq #'harness-ui-access-check-openshell (key-binding (kbd "O"))))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) messages)))))
        ;; The test: what it says is shown, and nothing else changes.
        (harness-ui-access-test-click "[Test OpenShell]" (harness-ui-access--find-anchor '(setting . sandbox)))
        (harness-test-wait (lambda () (member "OpenShell started a sandbox and ran a command in it" messages))
                           5 "what the test said")
        (should (= 1 checks))
        (should (eq 'bwrap (plist-get status :backend)))
        ;; Detecting again moves to OpenShell, says so, and the row follows.
        (harness-ui-access-test-click "[Detect again]" (harness-ui-access--find-anchor '(setting . sandbox)))
        (harness-test-wait (lambda () (member "Sandbox backend: openshell" messages)) 5 "the backend named")
        (harness-ui-access-test-wait-setting 'sandbox "\\`Sandbox openshell ")
        (should (string-match-p "Limit · No Linux capability can be given\\."
                                (harness-ui-access-test-setting 'sandbox)))
        (should-not (string-match-p "asked for, not used" (harness-ui-access-test-text)))
        ;; Still unusable: it says why.
        (setq status '(:backend bwrap :available (bwrap openshell) :policy preferred))
        (harness-register-method 'sandbox/detect
                                 (lambda ()
                                   '(:backend bwrap :available (bwrap openshell) :policy preferred
                                     :requested openshell :problem "no gateway is registered")))
        (harness-ui-access-test-click "[Detect again]" (harness-ui-access--find-anchor '(setting . sandbox)))
        (harness-test-wait (lambda () (member "Sandbox backend: bwrap (OpenShell cannot be used: no gateway is registered)"
                                              messages))
                           5 "the problem named")))))

(ert-deftest harness-ui-access-sandbox-buttons-in-a-harness-without-openshell ()
  "The Sandbox row of a machine that has no OpenShell, and asked for none, has no button for it."
  (harness-ui-access-test-with
    (harness-register-method 'sandbox/status (lambda () '(:backend bwrap :available (bwrap systemd) :policy preferred)))
    (harness-ui-access-test-open sid)
    (should-not (string-match-p "\\[Detect again\\]\\|\\[Test OpenShell\\]" (harness-ui-access-test-text)))))

(ert-deftest harness-ui-access-choices-change-the-settings ()
  "A choice that is not in effect is a button that takes it, and the view follows:
the permission mode, whether the session asks you, the network and writing.  The
one in effect is no button."
  (harness-ui-access-test-with
    (let ((messages nil))
      (harness-ui-access-test-open sid)
      ;; The choice in effect is bold and does nothing; the others are buttons.
      (goto-char (harness-ui-access--find-anchor '(setting . mode)))
      (search-forward "Ask")
      (should-not (get-text-property (1- (point)) 'harness-ui-action))
      (should (eq 'bold (get-text-property (1- (point)) 'face)))
      (search-forward "Accept Edits")
      (should (get-text-property (1- (point)) 'harness-ui-action))
      (should (string-match-p "Accept Edits: Project reads and edits (choice)"
                              (get-text-property (1- (point)) 'help-echo)))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) messages)))))
        ;; The permission mode.
        (harness-ui-access-test-click "Accept Edits" (harness-ui-access--find-anchor '(setting . mode)))
        (harness-ui-access-test-wait-setting 'mode "\\`Permission mode ( ) Ask (x) Accept Edits ( ) Auto ( ) YOLO Project reads and edits")
        (should (eq 'accept-edits (plist-get (harness-call 'session/get sid) :permission-mode)))
        (harness-ui-access-test-click "YOLO" (harness-ui-access--find-anchor '(setting . mode)))
        (harness-ui-access-test-wait-setting 'mode "( ) Accept Edits ( ) Auto (x) YOLO")
        (should (eq 'yolo (plist-get (harness-call 'session/get sid) :permission-mode)))
        (harness-test-wait (lambda () (member "Permission mode → YOLO" messages)) 5 "the message")
        ;; Whether you are asked.
        (harness-ui-access-test-click "Non-interactive" (harness-ui-access--find-anchor '(setting . interaction)))
        (harness-ui-access-test-wait-setting 'interaction "( ) Interactive (x) Non-interactive No prompts · decisions by the auto-mode judge")
        (should (harness-json-true-p (plist-get (harness-call 'session/get sid) :non-interactive)))
        (harness-ui-access-test-click "Interactive" (harness-ui-access--find-anchor '(setting . interaction)))
        (harness-ui-access-test-wait-setting 'interaction "(x) Interactive ( ) Non-interactive prompts · undecided calls")
        (should-not (harness-json-true-p (plist-get (harness-call 'session/get sid) :non-interactive)))
        ;; The network.
        (harness-ui-access-test-click "Off" (harness-ui-access--find-anchor '(setting . network)))
        (harness-ui-access-test-wait-setting 'network "\\`Network ( ) On (x) Off No web tools or ssh")
        (should-not (harness-access-network-p (harness-call 'session/get sid)))
        (harness-ui-access-test-click "On" (harness-ui-access--find-anchor '(setting . network)))
        (harness-ui-access-test-wait-setting 'network "\\`Network (x) On ( ) Off\\'")
        (should (harness-access-network-p (harness-call 'session/get sid)))
        ;; Writing.
        (harness-ui-access-test-click "Read-only" (harness-ui-access--find-anchor '(setting . writing)))
        (harness-ui-access-test-wait-setting 'writing "\\`Writing ( ) On (x) Read-only Reading tools only")
        (should (harness-readonly-session-p (harness-call 'session/get sid)))
        (harness-ui-access-test-click "On" (harness-ui-access--find-anchor '(setting . writing)))
        (harness-ui-access-test-wait-setting 'writing "\\`Writing (x) On ( ) Read-only\\'")
        (should-not (harness-readonly-session-p (harness-call 'session/get sid)))))
    ;; Where a click left point, the redraw leaves it: not at the top.
    (should (> (point) (harness-ui-access--find-anchor '(section . settings))))))

(ert-deftest harness-ui-access-settings-a-policy-fixes-leave-no-choice ()
  "A setting an administrator's policy sets, or another module's policy fixes,
shows the choice in effect and offers no other: nothing is a button, and the
row says who decides."
  (harness-ui-access-test-with
    (harness-ui-access-test-open sid)
    (setq harness-ui-access--describe
          (let ((d (copy-sequence harness-ui-access--describe)))
            (dolist (change '((:mode-pinned t) (:non-interactive-pinned t)
                              (:read-only t) (:read-only-profile nil) (:read-only-by "supervisor mode")))
              (setq d (plist-put d (car change) (cadr change))))
            d))
    (harness-ui-access--render)
    (should (equal "Permission mode (x) Ask ( ) Accept Edits ( ) Auto ( ) YOLO Writes, commands, network · ask · set by the policy"
                   (harness-ui-access-test-setting 'mode)))
    (should (equal "Interaction (x) Interactive ( ) Non-interactive prompts · undecided calls · set by the policy"
                   (harness-ui-access-test-setting 'interaction)))
    (should (equal "Writing ( ) On (x) Read-only Read-only by supervisor mode"
                   (harness-ui-access-test-setting 'writing)))
    (dolist (name '(mode interaction writing))
      (let* ((start (harness-ui-access--find-anchor (cons 'setting name)))
             (end (next-single-property-change start 'harness-ui-access-anchor)))
        ;; No text of the row runs anything.
        (should-not (text-property-not-all start end 'harness-ui-action nil))))
    ;; The commands say so as well.
    (let ((err (should-error (harness-ui-access-toggle-writing) :type 'user-error)))
      (should (string-match-p "Read-only · supervisor mode · not changeable here" (cadr err))))))

;;;; The Tools page

(ert-deftest harness-ui-access-tools-page-turns-tools-off-and-on ()
  "The Tools page lists the tools the session is offered, each a button that
turns it off, and those it is not, by why: the ones turned off for it buttons
that turn them on, the others named, the network's with a button to give it
back.  Those that belong to other kinds of session are named apart, with no
button: nobody turned them off."
  (harness-ui-access-test-with
    ;; A tool of other kinds of session, as hand_in is a task's.
    (harness-define-tool "test_hand_in" :label "Test hand in" :kind 'meta
                         :description "Hand nothing in." :handler (lambda (_input _ctx) (harness-tool-ok "handed in")))
    (harness-add-filter 'agent/tools (lambda (names _session) (remove "test_hand_in" names)) 50)
    (harness-ui-access-test-open sid 'tools)
    (should (eq 'tools harness-ui-access--page))
    (should (string-match-p "^Tools  [0-9]+ offered · 0 off · 1 for other kinds of session$"
                            (harness-ui-access-test-text)))
    (should (string-match-p "^For other kinds of session  1\n  test_hand_in" (harness-ui-access-test-text)))
    (should-not (string-match-p "^Off  " (harness-ui-access-test-text)))
    (goto-char (point-min))
    (search-forward "test_hand_in")
    (should-not (get-text-property (match-beginning 0) 'harness-ui-action))
    ;; Offered: a name is a button, and asks before it turns the tool off.
    (goto-char (point-min))
    (search-forward "test_fetch")
    (should (get-text-property (match-beginning 0) 'harness-ui-action))
    (let ((asked nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (push prompt asked) nil)))
        (harness-ui-access-test-click "test_fetch"))
      (should (equal '("Tool off · test_fetch") asked)))
    ;; The answer was no.
    (should-not (member "test_fetch" (plist-get (harness-access-profile (harness-call 'session/get sid)) :tools-off)))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
      (harness-ui-access-test-click "test_fetch"))
    (harness-ui-access-test-wait-text "^Off  1\n  turned off +test_fetch")
    (should (member "test_fetch" (plist-get (harness-access-profile (harness-call 'session/get sid)) :tools-off)))
    (should (string-match-p "^Tools  [0-9]+ offered · 1 off · 1 for other kinds of session$"
                            (harness-ui-access-test-text)))
    ;; Off: the name is a button that turns it on again.
    (harness-ui-access-test-click "test_fetch" (harness-ui-access--find-anchor '(section . off)))
    (harness-ui-access-test-wait-text "^Off  " t)
    (should-not (member "test_fetch" (plist-get (harness-access-profile (harness-call 'session/get sid)) :tools-off)))
    ;; With no network the tools that need it are off, and the page gives it back.
    (harness-call 'access/set-network sid :false)
    (harness-ui-access-test-wait-text "no network +test_fetch")
    (should (string-match-p "no network +.*test_fetch.*\\[Turn the network on\\]" (harness-ui-access-test-text)))
    (should-not (get-text-property
                 (progn (goto-char (harness-ui-access--find-anchor '(section . off)))
                        (search-forward "test_fetch") (match-beginning 0))
                 'harness-ui-action))
    (harness-ui-access-test-click "[Turn the network on]")
    (harness-ui-access-test-wait-text "^Off  " t)
    (should (harness-access-network-p (harness-call 'session/get sid)))
    ;; The command turns one off too, by name.
    (harness-ui-access-set-tool "test_fetch" nil)
    (harness-ui-access-test-wait-text "turned off +test_fetch")
    (harness-ui-access-toggle-tool "test_fetch")
    (harness-ui-access-test-wait-text "turned off +test_fetch" t)))

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
  "Return the line of the capabilities row of the view, flat; its note is below it."
  (let ((start (harness-ui-access--find-anchor '(setting . capabilities))))
    (should start)
    (save-excursion
      (goto-char start)
      (harness-ui-access-test-flat-string
       (buffer-substring-no-properties (line-beginning-position) (line-end-position))))))

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
  "The settings have a capabilities row, after writing: none, and every
capability is dropped, until the session's commands are given some; then it
names them, with the buttons to give more and take them away, and says what
they mean."
  (harness-ui-access-test-with-jail
    (harness-ui-access-test-open sid)
    (should (equal "Capabilities none [Give…]" (harness-ui-access-test-capabilities-row)))
    (should (equal "Capabilities none [Give…] All capabilities dropped"
                   (harness-ui-access-test-setting 'capabilities)))
    (should-not (string-match-p "\\[Take away…\\]\\|\\[Take all away\\]" (harness-ui-access-test-text)))
    ;; In the settings: after writing, before the sandbox they run in and the directories.
    (let ((writing (harness-ui-access--find-anchor '(setting . writing)))
          (row (harness-ui-access--find-anchor '(setting . capabilities)))
          (sandbox (harness-ui-access--find-anchor '(setting . sandbox)))
          (dirs (harness-ui-access--find-anchor '(section . directories))))
      (should (< writing row sandbox dirs)))
    ;; The tooltips end with the key.
    (goto-char (point-min))
    (search-forward "[Give…]")
    (should (string-match-p "Linux capability · sandboxed commands (C)"
                            (get-text-property (match-beginning 0) 'help-echo)))
    ;; One given.
    (harness-call 'access/set-capability sid "CAP_SYS_PTRACE" t)
    (harness-ui-access-test-wait-flat "Capabilities CAP_SYS_PTRACE")
    (should (equal "Capabilities CAP_SYS_PTRACE [Give…] [Take away…] [Take all away]"
                   (harness-ui-access-test-capabilities-row)))
    (should (string-match-p "Passed to bash and elisp commands · inside the sandbox only"
                            (harness-ui-access-test-flat)))
    (goto-char (point-min))
    (re-search-forward "Capabilities +\\(CAP_SYS_PTRACE\\)")
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
    (should (equal "Capabilities CAP_SYS_PTRACE, CAP_NET_RAW, CAP_NET_ADMIN, CAP_NET_BIND_SERVICE [Take away…] [Take all away]"
                   (harness-ui-access-test-capabilities-row)))
    ;; Taken away elsewhere, the view follows.
    (harness-call 'access/set-capability sid "all" :false)
    (harness-ui-access-test-wait-flat "Capabilities none \\[Give…\\] All capabilities dropped")
    (should-not (harness-ui-access-test-caps sid))))

(ert-deftest harness-ui-access-capabilities-row-says-why-none-can-be-raised ()
  "When no capability can be given -- the jail cannot, the session is read-only,
the user lets agents ask for none -- the row says why, and offers no [Give…]."
  (harness-ui-access-test-with-jail
    (setq harness-ui-access-test--jail
          (harness-ui-access-test--jail :enforced nil :backend 'systemd
                                        :why "the sandbox backend is systemd-run, not bwrap"))
    (harness-ui-access-test-open sid)
    (should (equal "Capabilities none" (harness-ui-access-test-capabilities-row)))
    (should (equal "Capabilities none All capabilities dropped · Unavailable: the sandbox backend is systemd-run, not bwrap"
                   (harness-ui-access-test-setting 'capabilities)))
    (should-not (string-match-p "\\[Give…\\]" (harness-ui-access-test-text)))
    ;; Where the jail can, a read-only session still cannot.
    (setq harness-ui-access-test--jail harness-ui-access-test--jail-enforcing)
    (harness-call 'access/set-read-only sid t)
    (harness-ui-access-test-wait-flat "Unavailable: this session is read-only")
    (should-not (string-match-p "\\[Give…\\]" (harness-ui-access-test-text)))
    (harness-call 'access/set-read-only sid :false)
    (harness-ui-access-test-wait-flat "Unavailable" t)
    (should (string-match-p "\\[Give…\\]" (harness-ui-access-test-text)))
    ;; Nothing the user lets agents ask for.
    (setq harness-ui-access-test--jail (harness-ui-access-test--jail :grantable nil :docs nil))
    (harness-ui-access-test-wait-flat "Unavailable: the user lets agents ask for no capability")
    (should-not (string-match-p "\\[Give…\\]" (harness-ui-access-test-text)))))

(ert-deftest harness-ui-access-capabilities-row-says-when-those-held-are-not-passed ()
  "A capability the session's commands hold that the sandbox does not pass on
-- the session is read-only, the jail cannot enforce it, the user no longer
lets agents ask for it -- is named with the reason, and can be taken away."
  (harness-ui-access-test-with-jail
    (harness-call 'access/set-capability sid "CAP_SYS_PTRACE" t)
    (harness-call 'access/set-capability sid "CAP_NET_RAW" t)
    (harness-ui-access-test-open sid)
    (should (string-match-p "Capabilities CAP_SYS_PTRACE, CAP_NET_RAW \\[Give…\\] \\[Take away…\\] \\[Take all away\\]"
                            (harness-ui-access-test-flat)))
    ;; Read-only: held, and no [Give…].
    (harness-call 'access/set-read-only sid t)
    (harness-ui-access-test-wait-flat "Held, not passed · read-only session")
    (should (equal "Capabilities CAP_SYS_PTRACE, CAP_NET_RAW [Take away…] [Take all away]"
                   (harness-ui-access-test-capabilities-row)))
    (should-not (string-match-p "Passed to bash and elisp commands" (harness-ui-access-test-flat)))
    (harness-call 'access/set-read-only sid :false)
    (harness-ui-access-test-wait-flat "Held, not passed" t)
    ;; The jail cannot pass them on.
    (setq harness-ui-access-test--jail
          (harness-ui-access-test--jail :enforced nil :backend 'systemd
                                        :why "the sandbox backend is systemd-run, not bwrap"))
    (harness-ui-access-test-wait-flat "Held, not passed: the sandbox backend is systemd-run, not bwrap")
    (should (equal "Capabilities CAP_SYS_PTRACE, CAP_NET_RAW [Take away…] [Take all away]"
                   (harness-ui-access-test-capabilities-row)))
    ;; One the user no longer lets agents ask for.
    (setq harness-ui-access-test--jail (harness-ui-access-test--jail :grantable '("CAP_NET_RAW")))
    (harness-ui-access-test-wait-flat "CAP_SYS_PTRACE held, not passed: no longer offered to agents")
    (should (equal "Capabilities CAP_SYS_PTRACE, CAP_NET_RAW [Take away…] [Take all away]"
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
                      (harness-ui-access-test-wait-flat "Unavailable")
                      (should-error (call-interactively #'harness-ui-access-toggle-capability) :type 'user-error))))
      (should (string-match-p "No capability · the sandbox backend is systemd-run" (cadr err))))
    (should-error (call-interactively #'harness-ui-access-grant-capability) :type 'user-error)
    (let ((err (should-error (call-interactively #'harness-ui-access-revoke-capability) :type 'user-error)))
      (should (string-match-p "No capability" (cadr err))))
    ;; Everything given: nothing left to give.
    (setq harness-ui-access-test--jail harness-ui-access-test--jail-enforcing)
    (dolist (name '("CAP_SYS_PTRACE" "CAP_NET_RAW" "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE"))
      (harness-call 'access/set-capability sid name t))
    (harness-ui-access-test-wait-flat "CAP_NET_BIND_SERVICE")
    (let ((err (should-error (call-interactively #'harness-ui-access-grant-capability) :type 'user-error)))
      (should (string-match-p "All capabilities granted" (cadr err))))))

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
    (should (harness-ui-access--find-anchor '(setting . capabilities)))
    (dolist (capabilities '(:absent nil))
      (setq harness-ui-access--describe
            (if (eq capabilities :absent)
                (harness-plist-remove harness-ui-access--describe :capabilities)
              (plist-put (copy-sequence harness-ui-access--describe) :capabilities nil)))
      (harness-ui-access--render)
      (should-not (harness-ui-access--find-anchor '(setting . capabilities)))
      (should-not (string-match-p "capabilities" (harness-ui-access-test-text)))
      (should (string-match-p "^  Writing +" (harness-ui-access-test-text)))
      (should (string-match-p "^  Sandbox +" (harness-ui-access-test-text)))
      (should (string-match-p "^Directories" (harness-ui-access-test-text)))
      (let ((err (should-error (call-interactively #'harness-ui-access-toggle-capability) :type 'user-error)))
        (should (string-match-p "No capability data" (cadr err)))))
    ;; The row comes back with the next fetch.
    (harness-ui-access-refresh)
    (harness-test-wait (lambda () (harness-ui-access--find-anchor '(setting . capabilities))) 5 "the row")))

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

(ert-deftest harness-ui-access-filter-buttons-ask-what-to-filter-by ()
  "The judgements' filter buttons -- who decided, the tool, a text -- ask for
the value and filter by it.  A click gives a button's action no arguments, and
each of these runs a command that takes the value: they signalled
wrong-number-of-arguments."
  (harness-ui-access-test-with
    (harness-ui-access-test-open sid 'judgements)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt &rest _)
                 (cond ((string-prefix-p "Decided by" prompt) "you (user)")
                       ((string-prefix-p "Tool" prompt) "test_fetch")
                       (t (error "Unexpected prompt %s" prompt)))))
              ((symbol-function 'read-string)
               (lambda (&rest _) "may not reach")))
      (harness-ui-access-test-click "[decided by: anyone]")
      (harness-ui-access-test-wait-text "\\[decided by: you\\]")
      (should (equal '(:by "user") harness-ui-access--filter))
      (harness-ui-access-test-click "[tool: any]")
      (harness-ui-access-test-wait-text "\\[tool: test_fetch\\]")
      (harness-ui-access-test-click "[text: —]")
      (harness-ui-access-test-wait-text "\\[text: may not reach\\]")
      (should (equal '(:by "user" :tool "test_fetch" :query "may not reach") harness-ui-access--filter))
      (harness-ui-access-test-click "[Clear]")
      (harness-ui-access-test-wait-text "\\[text: —\\]")
      (should-not harness-ui-access--filter))))

(ert-deftest harness-ui-access-a-waiting-request-is-the-chats-to-answer ()
  "The view is for the settings and the jail, not for answering: a request the
session waits on has no panel, no heading and no answer button on the Overview
or the Judgements page.  Its call is counted and listed as waiting, with no
reason that repeats it, and the view follows when the answer is made elsewhere,
as the chat's panel makes it."
  (harness-ui-access-test-with
    (let* ((harness-provider-demo-script-override
            '((:type tool-call :id "w1" :name "test_fetch" :input (:url "https://example.com"))
              (:type done :stop-reason end-turn)))
           (turn (harness-call 'agent/prompt sid "go"))
           (case-fold-search nil)
           (answers "Waiting for you\\|Permission +Test fetch\\|\\[Allow\\]\\|\\[Deny\\]\\|More answers\\|waiting for your answer"))
      (harness-test-wait (lambda () (harness-call 'permission/pending sid)) 5 "the request")
      ;; The Overview: the settings lead, and the details count the call.
      (harness-ui-access-test-open sid)
      (harness-ui-access-test-wait-text "^  Judgements +1 call judged · allowed 0 · denied 0 · waiting 1$")
      (should-not (string-match-p answers (harness-ui-access-test-text)))
      (should-not (harness-ui-access--find-anchor '(section . waiting)))
      (should (< (point-min) (harness-ui-access--find-anchor '(section . settings))))
      (should-not (string-match-p "Settings" (substring (harness-ui-access-test-text) 0
                                                       (harness-ui-access--find-anchor '(section . settings)))))
      ;; The Judgements page: the call, waiting, and nothing to answer it with.
      (harness-ui-access-test-open sid 'judgements)
      (harness-ui-access-test-wait-text "? waiting · handle w1")
      (should-not (string-match-p answers (harness-ui-access-test-text)))
      (should (string-match-p "\\[Waiting 1\\]" (harness-ui-access-test-text)))
      ;; The answer, made where the request is, shows here.
      (harness-call 'permission/answer sid (plist-get (car (harness-call 'permission/pending sid)) :id) "allow-once")
      (harness-test-await turn 20)
      (harness-ui-access-test-wait-text "✓ allowed by you · handle w1")
      (should-not (string-match-p "? waiting" (harness-ui-access-test-text))))))

;;;; The pages

(defun harness-ui-access-test-page-buffer (sid page)
  "Return the live view of SID's PAGE, or nil."
  (car (harness-ui-access--buffers sid page)))

(ert-deftest harness-ui-access-pages-are-views-of-their-own ()
  "The Overview, Tools, Rules and Judgements are four buffers of one session.
The strip under the title names them, the one shown marked and the others
buttons; a click, or the keys 1 to 4, shows another in place of this one; q
goes back to the Overview, and from the Overview leaves the view."
  (harness-ui-access-test-with
    (let* ((overview (harness-ui-access-test-open sid))
           (left nil))
      (should (string-prefix-p "*harness access: " (buffer-name overview)))
      (should (eq 'overview harness-ui-access--page))
      ;; The strip: the page shown is marked, and no button.
      (goto-char (point-min))
      (re-search-forward "^Overview")
      (should (eq 'harness-ui-access-page-face (get-text-property (match-beginning 0) 'face)))
      (should-not (get-text-property (match-beginning 0) 'harness-ui-action))
      (dolist (page '("Tools" "Rules" "Judgements"))
        (search-forward page)
        (should (get-text-property (match-beginning 0) 'harness-ui-action))
        (should (string-match-p "([234])\\'" (get-text-property (match-beginning 0) 'help-echo))))
      ;; A click on one shows it, as a view of its own, where this one was.
      (let ((where (get-buffer-window overview)))
        (should where)
        (harness-ui-access-test-click "Tools" (save-excursion (goto-char (point-min))
                                                              (re-search-forward "^Overview")
                                                              (match-beginning 0)))
        (let ((tools (harness-ui-access-test-page-buffer sid 'tools)))
          (should tools)
          (should (string-prefix-p "*harness access tools: " (buffer-name tools)))
          (should (eq tools (window-buffer where)))
          (should-not (get-buffer-window overview))
          (set-buffer tools)
          (harness-test-wait (lambda () harness-ui-access--describe) 5 "the Tools page")
          (should (eq 'tools harness-ui-access--page))
          (should (string-match-p "^Tools  [0-9]+ offered" (harness-ui-access-test-text)))
          (should (string-match-p "^Jail & permissions of " (harness-ui-access-test-text)))
          ;; The strip is on every page, this one's marked.
          (goto-char (point-min))
          (re-search-forward "^Overview  ·  Tools")
          (should-not (eq 'harness-ui-access-page-face (get-text-property (match-beginning 0) 'face)))
          (should (get-text-property (match-beginning 0) 'harness-ui-action))))
      ;; The keys.
      (dolist (case '(("3" rules "^Rules  first match, after the jail")
                      ("5" secrets "^Protection$")
                      ("4" judgements "^Judgements  ")
                      ("2" tools "^Tools  [0-9]+ offered")
                      ("1" overview "^Settings$")))
        (call-interactively (key-binding (kbd (nth 0 case))))
        (let ((buffer (harness-ui-access-test-page-buffer sid (nth 1 case))))
          (should (eq buffer (window-buffer (get-buffer-window buffer))))
          (set-buffer buffer)
          (harness-test-wait (lambda () harness-ui-access--describe) 5 "the page")
          (harness-ui-access-test-wait-text (nth 2 case))))
      ;; Five buffers, one a page, and each the session's.
      (should (= 5 (length (harness-ui-access--buffers sid))))
      ;; q from another page goes back to the Overview; from the Overview it leaves.
      (set-buffer (harness-ui-access-test-page-buffer sid 'judgements))
      (cl-letf (((symbol-function 'harness-ui-quit-view) (lambda () (setq left t))))
        (call-interactively (key-binding (kbd "q")))
        (should-not left)
        (should (eq overview (window-buffer (get-buffer-window overview))))
        (set-buffer overview)
        (call-interactively (key-binding (kbd "q")))
        (should left)))))

(ert-deftest harness-ui-access-details-link-to-their-pages ()
  "Each of the Overview's details is a line, all of it a link, that opens its
page: the tools, the rules, the judgements."
  (harness-ui-access-test-with
    (harness-ui-access-test-open sid)
    (dolist (page '(tools rules judgements secrets))
      (let* ((anchor (cons 'detail page))
             (start (harness-ui-access--find-anchor anchor))
             (end (or (next-single-property-change start 'harness-ui-access-anchor) (point-max))))
        (should start)
        ;; The whole row is the link, and its tooltip names the key.
        (should-not (text-property-not-all (+ start 2) (1- end) 'harness-ui-action
                                           (get-text-property (+ start 2) 'harness-ui-action)))
        (should (string-match-p "([2345])\\'" (get-text-property (+ start 2) 'help-echo)))
        (set-buffer (harness-ui-access-test-page-buffer sid 'overview))
        (harness-ui-access-test-click (capitalize (symbol-name page)) start)
        (let ((buffer (harness-ui-access-test-page-buffer sid page)))
          (should buffer)
          (should (eq buffer (window-buffer (get-buffer-window buffer))))
          (set-buffer buffer)
          (harness-test-wait (lambda () harness-ui-access--describe) 5 "the page")
          (should (eq page harness-ui-access--page))
          (harness-ui-access-show-overview)
          (set-buffer (harness-ui-access-test-page-buffer sid 'overview)))))))

(ert-deftest harness-ui-access-pages-ask-for-what-they-draw ()
  "Every page asks for the session's description; the Overview and the Judgements
page also for its judgements -- the Overview for their counts, one beside them,
the Judgements page for as many as it lists; the Tools and Rules pages ask for
none.  No page asks for the requests the session waits on."
  (harness-ui-access-test-with
    (let ((asked nil)
          (call (symbol-function 'harness-ui-call)))
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (method params &rest rest)
                   (when (or (string-prefix-p "_harness/access/" method)
                             (string-prefix-p "_harness/session/pending" method))
                     (push (cons method (plist-get params :limit)) asked))
                   (apply call method params rest))))
        (dolist (case `((overview ("_harness/access/describe") ("_harness/access/judgements" . 1))
                        (tools ("_harness/access/describe"))
                        (rules ("_harness/access/describe"))
                        (secrets ("_harness/access/describe"))
                        (judgements ("_harness/access/describe")
                                    ("_harness/access/judgements" . ,harness-ui-access-judgements-limit))))
          (setq asked nil)
          (harness-ui-access-test-open sid (car case))
          (harness-test-wait (lambda () (= (length asked) (length (cdr case)))) 5 "the requests")
          (should (equal (sort (copy-sequence (cdr case)) (lambda (a b) (string< (car a) (car b))))
                         (sort (copy-sequence asked) (lambda (a b) (string< (car a) (car b)))))))))))

(ert-deftest harness-ui-access-hidden-pages-follow-the-session-when-shown ()
  "A page nothing shows is not drawn again at every change: it is marked, and
fetches once a window shows it.  The page that is shown follows at once."
  (harness-ui-access-test-with
    (let ((overview (harness-ui-access-test-open sid)))
      (harness-ui-access-show-page 'tools)
      (let ((tools (harness-ui-access-test-page-buffer sid 'tools)))
        (set-buffer tools)
        (harness-test-wait (lambda () harness-ui-access--describe) 5 "the Tools page")
        (should-not (get-buffer-window overview))
        (harness-call 'access/set-network sid :false)
        ;; The shown page follows: no network, so the tools that need it are off.
        (harness-ui-access-test-wait-text "no network +test_fetch")
        ;; The hidden one waits.  The event may have raced its own
        ;; callback in a full run; deliver it here with any other window on
        ;; the overview explicitly out of the picture.
        (with-current-buffer overview
          (cl-letf (((symbol-function 'harness-ui-view-shown-p)
                     (lambda (&optional buffer)
                       (and (not (eq (or buffer (current-buffer)) overview))
                            (get-buffer-window (or buffer (current-buffer)) t)
                            t))))
            (harness-ui-access--on-event "access/changed" (list sid)))
          (harness-test-wait (lambda () harness-ui-access--stale) 5 "the hidden page marked stale")
          (should (equal "Network (x) On ( ) Off" (harness-ui-access-test-setting 'network))))
        (set-buffer tools)
        (harness-ui-access-show-overview)
        (set-buffer overview)
        (harness-ui-access-test-wait-setting 'network "\\`Network ( ) On (x) Off")))))

;;;; Following the permission mode on a chat's settings line

(defun harness-ui-access-test-settings-segment (buffer label)
  "Return (LINE . POS) of the settings-line button LABEL in BUFFER, or nil.
LINE is the whole settings line the view builds, with its properties: the
view need not be drawn in a window for it to exist."
  (with-current-buffer buffer
    (harness-test-wait (lambda () (harness-chat--session)) 5 "the chat's session")
    (let* ((line (harness-chat--settings-line most-positive-fixnum))
           (pos (and line (string-search label (substring-no-properties line)))))
      (and pos (functionp (get-text-property pos 'harness-ui-action line))
           (cons line pos)))))

(ert-deftest harness-ui-access-opens-from-the-permission-mode-on-the-chats-settings-line ()
  "A click on the permission mode on a chat's settings line opens the session's
jail and permissions view, rather than asking which mode to choose; its tooltip
says what the mode means and where a click goes."
  (harness-ui-access-test-with
    (let* ((chat (harness-chat-buffer sid))
           (window (selected-window))
           (segment (harness-ui-access-test-settings-segment chat "Ask")))
      (set-window-buffer window chat)
      (should segment)
      (let ((line (car segment)) (pos (cdr segment)))
        (should (equal "Ask" (substring-no-properties line pos (+ pos 3))))
        (let ((help (funcall (get-text-property pos 'help-echo line) window nil nil)))
          (should (string-match-p "\\`Permission mode: Ask — writes, commands, network · ask" help))
          (should (string-match-p "mouse-1: jail and permissions" help))
          (should (string-match-p "change mode" help))
          (should-not (string-match-p "\n" help)))
        ;; The click, in the chat's buffer as a mouse-1 there is.
        (should-not (harness-ui-access-test-page-buffer sid 'overview))
        (with-current-buffer chat
          (funcall (get-text-property pos 'harness-ui-action line))))
      (let ((view (harness-ui-access-test-page-buffer sid 'overview)))
        (should view)
        (should (get-buffer-window view))
        (set-buffer view)
        (harness-test-wait (lambda () harness-ui-access--describe) 5 "the view")
        (should (equal sid harness-ui-session-id))
        (should (equal "Permission mode (x) Ask ( ) Accept Edits ( ) Auto ( ) YOLO Writes, commands, network · ask"
                       (harness-ui-access-test-setting 'mode)))
        ;; The mode is chosen there, and the chat's header follows.
        (harness-ui-access-test-click "Auto" (harness-ui-access--find-anchor '(setting . mode)))
        (harness-ui-access-test-wait-setting 'mode "\\`Permission mode ( ) Ask ( ) Accept Edits (x) Auto")
        (harness-test-wait (lambda () (equal "auto" (format "%s" (plist-get (harness-ui-session sid) :permission-mode))))
                           5 "the cached mode")
        (harness-test-wait (lambda ()
                             (string-search "Auto" (with-current-buffer chat
                                                     (harness-chat--settings-line most-positive-fixnum))))
                           5 "the settings line to say Auto")))))

(ert-deftest harness-ui-access-permission-mode-chooses-where-the-view-is-not-loaded ()
  "Where the access view is not there to open -- its module is off -- a click on
the permission mode on the settings line chooses the mode, as it did before the view."
  (harness-ui-access-test-with
    (should (eq #'harness-access (harness-chat--permission-command)))
    (cl-letf (((symbol-function 'harness-access) nil))
      (should (eq #'harness-set-permission-mode (harness-chat--permission-command)))
      (let* ((chat (harness-chat-buffer sid))
             (segment (harness-ui-access-test-settings-segment chat "Ask")))
        (should segment)
        (should (string-match-p "mouse-1: change mode"
                                (funcall (get-text-property (cdr segment) 'help-echo (car segment))
                                         (selected-window) nil nil)))))))

;;;; Looking at it

(ert-deftest harness-ui-access-tab-goes-from-button-to-button ()
  "TAB goes to the next button, S-TAB to the previous, round the buttons of the
page: the strip's, the choices', the directories' and the details' links.  On a
call's own text it folds the call instead."
  (harness-ui-access-test-with
    (harness-ui-access-test-open sid)
    (let ((starts (harness-ui-access--button-starts)))
      (should (> (length starts) 15))
      ;; Each is where text that does something starts.
      (dolist (start starts)
        (should (get-text-property start 'harness-ui-action))
        (should-not (and (> start (point-min))
                         (eq (get-text-property start 'harness-ui-action)
                             (get-text-property (1- start) 'harness-ui-action)))))
      (should (eq #'harness-ui-access-toggle (key-binding (kbd "TAB"))))
      (should (eq #'harness-ui-access-previous-button (key-binding (kbd "<backtab>"))))
      (goto-char (point-min))
      (let (seen)
        (dotimes (_ (length starts))
          (call-interactively #'harness-ui-access-toggle)
          (push (point) seen))
        (should (equal starts (nreverse seen))))
      ;; Past the last the first is next, and before the first the last.
      (call-interactively #'harness-ui-access-toggle)
      (should (= (point) (car starts)))
      (call-interactively #'harness-ui-access-previous-button)
      (should (= (point) (car (last starts))))
      (call-interactively #'harness-ui-access-previous-button)
      (should (= (point) (car (last starts 2)))))))

(defun harness-ui-access-test-fit (limit &rest kinds)
  "Check that no line of the rows anchored as KINDS in the view is wider than LIMIT.
A kind is `setting', `dir', `detail' or `section'.  The rows must be there."
  (let ((pos (point-min)) (rows 0))
    (while (setq pos (next-single-property-change pos 'harness-ui-access-anchor))
      (let ((anchor (get-text-property pos 'harness-ui-access-anchor)))
        (when (and anchor (memq (car anchor) kinds))
          (cl-incf rows)
          (let ((end (or (next-single-property-change pos 'harness-ui-access-anchor) (point-max))))
            (save-excursion
              (goto-char pos)
              (while (< (point) end)
                (let ((line (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
                  (ert-info ((format "the line %S of %S" line anchor))
                    (should (<= (string-width line) limit))))
                (forward-line 1)))))))
    (should (> rows 0))))

(ert-deftest harness-ui-access-rows-fit-a-narrow-window ()
  "The rows of the settings, the directories and the details fit the window they
are drawn for.  The path of a directory is cut in the middle, where its end is
kept.  Where that leaves too little of it beside the buttons, the source and
the buttons go on a line under the path; a wide window keeps them in one row."
  (harness-ui-access-test-with
    (let ((long (concat (harness-test-temp-dir) "a-directory-with-a-rather-long-name/inside/it/and/again/project/")))
      (make-directory long t)
      (harness-call 'permission/allow-dir sid long)
      ;; Wide: a row is one line.
      (let ((harness-ui-access-test-width 110))
        (harness-ui-access-test-open sid)
        (harness-ui-access-test-wait-text "granted to this session")
        (harness-ui-access-test-fit 110 'setting 'dir 'detail 'section)
        (let ((row (harness-ui-access-test-row long)))
          (should (string-match-p "^  rw  /tmp/harness-tmp-[^ ]*…[^ ]*again/project/ +granted to this session +\\[Revocation\\] \\[Read only\\]" row))))
      ;; Narrow: the path has a line, and the source and the buttons the next.
      (let ((harness-ui-access-test-width 56))
        (harness-ui-access-refresh)
        (harness-ui-access-test-wait-text "^      granted to this session  \\[Revocation\\] \\[Read only\\]$")
        (harness-ui-access-test-fit 56 'setting 'dir 'detail 'section)
        (let ((row (harness-ui-access-test-row long)))
          (should (string-match-p "^  rw  /tmp/[^ ]*…[^ ]*again/project/$" row))
          (should (<= (string-width row) 56)))
        ;; The choices of a setting, and its note, wrap under each other.
        (let ((start (harness-ui-access--find-anchor '(setting . mode))))
          (should (>= (count-lines start (next-single-property-change start 'harness-ui-access-anchor)) 3))
          (should (equal "Permission mode (x) Ask ( ) Accept Edits ( ) Auto ( ) YOLO Writes, commands, network · ask"
                         (harness-ui-access-test-setting 'mode))))))))


(ert-deftest harness-ui-access-waiting-request-shows-what-a-model-says-its-call-does ()
  "With summaries on, the request the session waits on gets what a cheap model
writes of its call: the whole way, from the permission chain through the
session's pending list and the ACP events to the panel of the chat, which is
where a request is answered.  The access view draws no panel of its own (see
`harness-ui-access-a-waiting-request-is-the-chats-to-answer'), and follows
the answer made in the chat's.  The demo provider is the cheap model."
  (harness-ui-access-test-with
    (let* ((harness-perms-summarize t)
           (harness-provider-demo-script-override
            (lambda (request)
              (if (string-prefix-p "You explain one blocked tool call" (or (plist-get request :system) ""))
                  ;; The demo's own answer to a summary.
                  (let ((harness-provider-demo-script-override nil))
                    (harness-provider-demo--script request))
                '((:type tool-call :id "w1" :name "test_fetch" :input (:url "https://example.com"))
                  (:type done :stop-reason end-turn)))))
           (turn (harness-call 'agent/prompt sid "go")))
      (harness-test-wait (lambda () (harness-call 'permission/pending sid)) 5 "the request")
      (let ((chat (harness-chat-buffer sid)))
        (harness-test-wait (lambda () (with-current-buffer chat (and (not harness-chat--loading) harness-compose-end)))
                           5 "the chat loaded")
        (harness-test-wait (lambda ()
                             (with-current-buffer chat
                               (string-search "Model summary · Calls test_fetch with the arguments shown"
                                              (buffer-substring-no-properties (point-min) (point-max)))))
                           5 "the summary in the chat's panel")
        (with-current-buffer chat
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (should-not (string-match-p "summarizing" text))
            (should (< (string-search "Permission" text) (string-search "Model summary ·" text)
                       (string-search "[Allow]" text))))
          ;; The request is the user's to answer, summary or not.
          (should (plist-get (plist-get (car (harness-call 'permission/pending sid)) :payload) :summary))
          ;; The view counts it, and draws nothing to answer it with.
          (harness-ui-access-test-open sid)
          (harness-ui-access-test-wait-text "^  Judgements +1 call judged · allowed 0 · denied 0 · waiting 1$")
          (should-not (string-match-p "Model summary\\|\\[Allow\\]" (harness-ui-access-test-text)))
          ;; Answered where the panel is.
          (set-buffer chat)
          (goto-char (point-min))
          (should (search-forward "[Allow]" nil t))
          (goto-char (1- (match-end 0)))
          (harness-chat-push)))
      (harness-test-await turn 20)
      (harness-ui-access-test-open sid 'judgements)
      (harness-ui-access-test-wait-text "✓ allowed by you · handle w1")
      (should-not (string-match-p "? waiting" (harness-ui-access-test-text))))))

;;;; Secrets: exact rendered copy, actions and asynchronous state

(defun harness-ui-access-test-copy-lines (text)
  "Return TEXT's nonblank lines with layout padding normalized."
  (delq nil (mapcar (lambda (line)
                     (let ((line (string-trim (replace-regexp-in-string "[ \t]+" " " line))))
                       (unless (string-empty-p line) line)))
                   (split-string text "\n"))))

(defun harness-ui-access-test-secret-copy (status)
  "Draw STATUS and return the exact rendered secret page copy."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (harness-ui-access--insert-secrets status))
  (harness-ui-access-test-copy-lines (harness-ui-access-test-text)))

(defun harness-ui-access-test-help (label)
  "Return the tooltip at LABEL in this buffer."
  (save-excursion
    (goto-char (point-min))
    (should (search-forward label nil t))
    (get-text-property (match-beginning 0) 'help-echo)))

(ert-deftest harness-ui-access-secrets-empty-and-state-copy ()
  "No sources is not inactive masking; all page states and tooltips are exact."
  (harness-ui-access-test-with
    (harness-test-load-module 'ui-secrets)
    (harness-test-load-module 'ui-config)
    (harness-ui-access-test-open sid 'secrets)
    (let* ((status '(:available t :masking t :detectors ("github-token" "secret-assignment")))
           (expected '("Protection" "Output masking On" "Tool-output detection · no project scan"
                       "File isolation No source-file isolation" "Detectors github-token · secret-assignment"
                       "Registered sources Harness-wide"
                       "[New source…] [Sources] [Redaction…] [History] [Settings]"
                       "No registered sources" "Detected in tool output This session · current harness run"
                       "0 masked values · 0 withheld" "No detections yet" "[Refresh]")))
      (should (equal expected (harness-ui-access-test-secret-copy status)))
      (dolist (pair '(("[New source…]" . "New secret source · harness-wide")
                      ("[Sources]" . "Registered secret sources")
                      ("[Redaction…]" . "Stored-secret redaction")
                      ("[History]" . "Redaction history")
                      ("[Settings]" . "Harness settings")
                      ("[Refresh]" . "Secret status refresh (g)")))
        (should (equal (cdr pair) (harness-ui-access-test-help (car pair)))))
      (should (equal "Masking on · 0 sources · 0 masked values" (harness-ui-access--secrets-summary status)))
      (setq status (plist-put status :masking :false))
      (setq expected (mapcar (lambda (s) (if (equal s "Output masking On") "Output masking Off" s)) expected))
      (should (equal expected (harness-ui-access-test-secret-copy status)))
      (should (equal "Masking off · 0 sources · 0 masked values" (harness-ui-access--secrets-summary status)))
      (should (equal '("Protection" "Secret extension inactive" "[Refresh]")
                     (harness-ui-access-test-secret-copy '(:available :false))))
      (should (equal "Extension inactive" (harness-ui-access--secrets-summary nil)))
      (should (equal '("Protection" "Secret status unavailable" "[Refresh]")
                     (harness-ui-access-test-secret-copy '(:available t :error "backend payload"))))
      (should (equal "Status unavailable" (harness-ui-access--secrets-summary '(:error "backend payload"))))
      (setq harness-ui-access--describe nil harness-ui-access--error nil)
      (harness-ui-access--render)
      (should (equal "Loading…\n" (harness-ui-access-test-text)))
      (setq harness-ui-access--error "backend payload")
      (harness-ui-access--render)
      (should (equal "Secret status unavailable\n[Refresh]\n" (harness-ui-access-test-text)))
      (should (equal "Secret status refresh (g)" (harness-ui-access-test-help "[Refresh]")))
      (setq harness-ui-access--describe nil)
      (cl-letf (((symbol-function 'harness-ui-session) (lambda (_) nil)))
        (should (equal " Jail & permissions: Secrets"
                       (substring-no-properties (harness-ui-access--header)))))
      (let ((inhibit-read-only t)) (erase-buffer) (harness-ui-access--insert-strip))
      (should (equal "Overview  ·  Tools  ·  Rules  ·  Judgements  ·  Secrets\n" (harness-ui-access-test-text)))
      (should (equal "Secret sources and detected tool output (5)" (harness-ui-access-test-help "Secrets")))
      (should (eq #'harness-ui-access-show-secrets (key-binding (kbd "5")))))))

(ert-deftest harness-ui-access-secrets-source-and-detection-copy ()
  "Sources and observed files remain separate; raw tool output is never drawn."
  (harness-ui-access-test-with
    (harness-test-load-module 'ui-secrets)
    (harness-test-load-module 'ui-config)
    (harness-ui-access-test-open sid 'secrets)
    (let* ((source '(:id "src-test" :label "deploy" :origin "stored" :values 1
                     :source "file /vault/deploy.json, JSON path token" :file "/vault/deploy.json"
                     :fingerprints ("aabbccdd") :error "missing file"))
           (status (list :available t :masking t :file-isolation t :sources (list source)
                         :masked-count 3 :withheld-count 1
                         :detections '((:tool "read_file" :file "/project/.env" :at 1700000000.0
                                        :content "raw output excluded"
                                        :masked ((:label "github-token" :fingerprint "12345678" :count 2)))
                                       (:tool "bash" :at 1700000000.0
                                        :masked ((:label "deploy" :fingerprint "aabbccdd" :count 1)))))))
      (cl-letf (((symbol-function 'harness-ui-tool-label)
                 (lambda (name) name))
                ((symbol-function 'harness-ui-access--time) (lambda (_) "12:00:00")))
        (should
         (equal '("Protection" "Output masking On" "Tool-output detection · no project scan"
                  "File isolation Source-file isolation enabled" "Detectors No active detectors"
                  "Registered sources Harness-wide"
                  "[New source…] [Sources] [Redaction…] [History] [Settings]"
                  "deploy 1 value · Stored [Removal…]"
                  "file /vault/deploy.json, JSON path token" "sha256:aabbccdd"
                  "Source unreadable · previous values retained" "missing file"
                  "Detected in tool output This session · current harness run" "3 masked values · 1 withheld"
                  "Read file · /project/.env · 12:00:00" "github-token · sha256:12345678 · 2 matches"
                  "Bash · Unknown file · 12:00:00" "deploy · sha256:aabbccdd · 1 match" "[Refresh]")
                (harness-ui-access-test-secret-copy status))))
      (should (equal "Source removal · harness-wide masking and file isolation"
                     (harness-ui-access-test-help "[Removal…]")))
      (setq source (plist-put source :origin "config"))
      (setq source (plist-put source :values 0))
      (let ((inhibit-read-only t)) (erase-buffer) (harness-ui-access--insert-secret-source source))
      (should (equal '("deploy 0 values · Configuration" "file /vault/deploy.json, JSON path token"
                       "sha256:aabbccdd" "Source unreadable" "missing file")
                     (harness-ui-access-test-copy-lines (harness-ui-access-test-text))))
      ;; Long paths and names fit even a narrow view; their tooltips retain the full data.
      (cl-letf (((symbol-function 'harness-ui-access--width) (lambda () 42)))
        (setq source (plist-put source :source (concat "/vault/" (make-string 150 ?x))))
        (let ((inhibit-read-only t)) (erase-buffer) (harness-ui-access--insert-secret-source source))
        (dolist (line (split-string (harness-ui-access-test-text) "\n"))
          (should (<= (string-width line) 42)))
        (should (equal (plist-get source :source)
                       (harness-ui-access-test-help "/vault/")))))))

(ert-deftest harness-ui-access-secrets-dispatch-actions-and-errors ()
  "Page actions reuse the source/redaction UI and retain failed changes in the page."
  (harness-ui-access-test-with
    (harness-test-load-module 'ui-secrets)
    (harness-test-load-module 'ui-config)
    (harness-ui-access-test-open sid 'secrets)
    (let ((buffer (current-buffer)) called)
      (cl-letf (((symbol-function 'harness-secrets-add-source)
                 (lambda (&optional _kind) (interactive) (push 'new called)))
                ((symbol-function 'harness-ui-secrets-remove)
                 (lambda (source _after on-error)
                   (push (plist-get source :id) called) (funcall on-error "Source removal failed: unavailable")))
                ((symbol-function 'harness-ui-access-refresh) (lambda (&optional b) (should (eq buffer b))))
                ((symbol-function 'harness-settings) (lambda (&optional _directory scope) (interactive) (push scope called))))
        (harness-ui-access-test-secret-copy
         '(:available t :masking t :sources ((:id "src-test" :label "deploy" :origin "stored" :values 1))))
        (harness-ui-access-test-push "[New source…]")
        (harness-ui-access-test-push "[Removal…]")
        (should (equal "Source removal failed: unavailable" harness-ui-access--secret-error))
        (harness-ui-access-test-secret-copy '(:available t :masking t))
        (should (member "Source removal failed: unavailable"
                        (harness-ui-access-test-copy-lines (harness-ui-access-test-text))))
        (harness-ui-access-test-push "[Settings]")
        (should (equal '(global "src-test" new) called))))))

(ert-deftest harness-ui-access-secrets-ignores-stale-fetches ()
  "The older response cannot replace a newer protection state, even after buffer death."
  (harness-ui-access-test-with
    (let ((buffer (harness-ui-access--buffer sid 'secrets)) callbacks)
      (with-current-buffer buffer
        (cl-letf (((symbol-function 'harness-ui-call)
                   (lambda (_method _params callback &optional _on-error) (push callback callbacks))))
          (harness-ui-access-refresh)
          (should (equal "Loading…\n" (harness-ui-access-test-text)))
          (harness-ui-access-refresh))
        (funcall (car callbacks) (list :session (list :id sid) :secrets '(:available t :masking t)))
        (funcall (cadr callbacks) (list :session (list :id sid) :secrets '(:available nil)))
        (should (harness-json-true-p (plist-get (plist-get harness-ui-access--describe :secrets) :masking)))
        (kill-buffer buffer)
        (funcall (car callbacks) '(:secrets (:available nil)))))))

(ert-deftest harness-ui-access-secrets-refetches-when-connection-replaced-mid-load ()
  "A first fetch on a replaced connection does not leave the page loading."
  (harness-ui-access-test-with
    (let ((buffer (harness-ui-access--buffer sid 'secrets))
          (old (list 'connection 'old))
          (new (list 'connection 'new))
          callbacks)
      (with-current-buffer buffer
        ;; The view opens before a connection exists; the first request
        ;; establishes it, and the buffer cannot record which one it was.
        (let ((harness-ui-connection nil))
          (cl-letf (((symbol-function 'harness-ui-call)
                     (lambda (_method _params callback &optional _on-error)
                       (setq harness-ui-connection old)
                       (push callback callbacks))))
            (harness-ui-access-refresh)
            (should (= 1 (length callbacks)))
            (should (equal "Loading…\n" (harness-ui-access-test-text)))
            (setq harness-ui-connection new)
            (harness-ui-access--reconnected)
            (should (= 2 (length callbacks)))
            ;; The answer the old connection owed is dropped; the new one draws.
            (funcall (nth 1 callbacks) (list :session (list :id sid) :secrets '(:available nil)))
            (should (equal "Loading…\n" (harness-ui-access-test-text)))
            (funcall (nth 0 callbacks)
                     (list :session (list :id sid) :secrets '(:available t :masking t :sources nil)))
            (should (string-match-p "^Protection$" (harness-ui-access-test-text)))))))))

(ert-deftest harness-ui-access-secrets-events-refresh-the-right-views ()
  "Detections belong to one session; registry changes affect every access view."
  (harness-ui-access-test-with
    (let* ((other (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted") :id))
           (one (harness-ui-access--buffer sid 'secrets))
           (two (harness-ui-access--buffer other 'overview)) scheduled)
      (cl-letf (((symbol-function 'harness-ui-access--schedule) (lambda (b) (push b scheduled))))
        (harness-ui-access--on-event "secrets/detected" (list sid))
        (should (equal (list one) scheduled))
        (setq scheduled nil)
        (harness-ui-access--on-event "secrets/sources-changed" nil)
        (should (equal (sort (mapcar #'buffer-name (list one two)) #'string<)
                       (sort (mapcar #'buffer-name scheduled) #'string<))))
      (should (memq 'secrets/detected harness-acp--forwarded-events))
      (should (memq 'secrets/sources-changed harness-acp--forwarded-events)))))

(provide 'harness-ui-access-test)
;;; harness-ui-access-test.el ends here
