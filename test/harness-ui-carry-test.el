;;; harness-ui-carry-test.el --- Tests for the panel that asks how to carry a conversation over  -*- lexical-binding: t; -*-

;;; Commentary:

;; The one panel the cold-cache question and the model switch are drawn
;; with (harness-ui-carry.el): what a spec makes of it, the keys that
;; answer, how a long wording breaks for a buffer that truncates its
;; lines, and the hosts that show a question until it is answered -- which
;; buffer is chosen, and that a question answered, replaced or left
;; behind by a dead buffer is answered once at most.  The questions' own
;; tests (harness-ui-cowboy-test.el, harness-ui-handoff-test.el) check
;; what they put in it, and that the hosts they use show it.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-carry)
(require 'harness-ui-carry)

(defvar harness-chat-panel-functions)
(defvar harness-ui-sessions-panel-functions)
(defvar harness-ui-tasks-panel-functions)
(defvar harness-compose-redraw-function)
(defvar harness-ui-sessions--buffer-name)

(defun harness-ui-carry-test--spec (&rest overrides)
  "Return a spec with a few priced choices, OVERRIDES put over it."
  (let ((spec (list :id "p1" :icon 'harness-icon-clock :title "Something cold" :detail "since 14:02"
                    :lines '("A line of context")
                    :rows '(("Waiting" "your message") ("Resend" "$0.315 uncached"))
                    :ask "Choose what goes first"
                    :choices (list (harness-carry-choice 'brief :cost-text "~$0.0040" :by "Cheap")
                                   (harness-carry-choice 'summary :cost-text "~$0.330")
                                   (harness-carry-choice 'transcript :cost-text "free")
                                   (harness-carry-choice 'hold))
                    :default "brief" :answer #'ignore)))
    (while overrides
      (setq spec (plist-put spec (pop overrides) (pop overrides))))
    spec))

(defun harness-ui-carry-test--lines (string)
  "Return the lines of STRING without its properties, trailing blanks trimmed."
  (mapcar #'string-trim-right (split-string (substring-no-properties string) "\n")))

(ert-deftest harness-ui-carry-panel-draws-a-spec ()
  "A spec makes a heading, dim lines, aligned rows, the imperative line,
a row per choice -- key, button, cost column, wording, the default marked --
and the line saying how to press a key from the compose box."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (let ((lines (harness-ui-carry-test--lines (harness-ui-carry-panel-string (harness-ui-carry-test--spec)))))
    (should (string-match-p "\\` .*Something cold  since 14:02\\'" (nth 0 lines)))
    (should (equal "   A line of context" (nth 1 lines)))
    (should (equal "   Waiting  your message" (nth 2 lines)))
    (should (equal "   Resend   $0.315 uncached" (nth 3 lines)))
    (should (equal "" (nth 4 lines)))
    (should (equal "   Choose what goes first" (nth 5 lines)))
    (should (equal '("    b  Brief summary    ~$0.0040  Cheap · narrative, tool calls in brief · first and last messages kept · default"
                     "    s  Summary          ~$0.330   whole conversation · first and last messages kept"
                     "    t  Transcript file  free      whole conversation as a file the model reads"
                     "    q  Not now                    message waits")
                   (seq-subseq lines 6 10)))
    (should (equal "   from the box: C-c . b" (nth 10 lines)))
    (should (= 12 (length lines)))))

(ert-deftest harness-ui-carry-panel-leaves-out-what-it-is-not-given ()
  "A spec with no costs has no cost column; with no rows and no lines, no
facts; with no imperative, none; `:hint' nil leaves out the compose box's
line; `:always' adds the capitals' line and says what they do."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (let* ((bare (harness-ui-carry-test--lines
                (harness-ui-carry-panel-string
                 (list :title "Bare" :choices (list (harness-carry-choice 'brief) (harness-carry-choice 'hold))
                       :hint nil))))
         (always (harness-ui-carry-test--lines
                  (harness-ui-carry-panel-string (harness-ui-carry-test--spec :always t :hint nil)))))
    (should (string-match-p "\\` .*Bare\\'" (nth 0 bare)))
    (should (equal '("" "    b  Brief summary  narrative, tool calls in brief · first and last messages kept"
                     "    q  Not now        message waits" "")
                   (cdr bare)))
    (should-not (cl-some (lambda (l) (string-match-p "from the box" l)) always))
    ;; The capitals of every choice but not now, then a blank, as the footer.
    (should (member "    B   S   T   default for every session, no asking" always))
    (should-not (member "    Q" always))))

(ert-deftest harness-ui-carry-panel-accepts-choices-as-a-vector ()
  "The choices come over the wire as a vector, and the panel draws them the same."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (let ((spec (harness-ui-carry-test--spec)))
    (should (equal (harness-ui-carry-test--lines (harness-ui-carry-panel-string spec))
                   (harness-ui-carry-test--lines
                    (harness-ui-carry-panel-string
                     (plist-put (copy-sequence spec) :choices (apply #'vector (plist-get spec :choices)))))))))

(ert-deftest harness-ui-carry-panel-properties ()
  "Every character of the panel belongs to it, in amber, and is a panel of the
compose box; a button says more when hovered; a wrapped line is indented
in amber too."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (let* ((string (harness-ui-carry-panel-string (harness-ui-carry-test--spec :always t))))
    (should (cl-loop for i from 0 below (length string)
                     always (equal "p1" (get-text-property i 'harness-ui-carry-panel string))))
    (should (cl-loop for i from 0 below (length string)
                     always (equal "p1" (get-text-property i 'harness-compose-panel string))))
    (should (memq 'harness-ui-carry-face (ensure-list (get-text-property 0 'face string))))
    (let ((prefix (get-text-property (string-search "Cheap" string) 'wrap-prefix string)))
      (should (string-blank-p prefix))
      (should (eq 'harness-ui-carry-face (get-text-property 0 'face prefix))))
    (let ((help (get-text-property (string-search "Brief summary" string) 'help-echo string)))
      (should (string-prefix-p "Brief summary (~$0.0040) · Cheap · narrative" help))
      (should (string-match-p " · Press b on this panel, or click; B: default for every session, no asking\\'" help))
      (should-not (string-match-p "\n" help)))
    ;; Not now has no capital.
    (let ((help (get-text-property (string-search "Not now" string) 'help-echo string)))
      (should (string-match-p " · Press q on this panel, or click\\'" help)))))

(ert-deftest harness-ui-carry-flow-breaks-between-segments ()
  "A wording breaks between its segments at the width, the next lines
indented under the first, and never inside a segment; with no width it is one line."
  (let ((segments '("Demo cheap" "narrative, tool calls in brief" "first and last messages kept" "default")))
    (should (equal "Demo cheap · narrative, tool calls in brief · first and last messages kept · default"
                   (harness-ui-carry--flow segments 10 nil)))
    (should (equal "Demo cheap · narrative, tool calls in brief\n          first and last messages kept · default"
                   (harness-ui-carry--flow segments 10 70)))
    (should (equal "Demo cheap\n    narrative, tool calls in brief\n    first and last messages kept\n    default"
                   (harness-ui-carry--flow segments 4 34)))
    (should (equal "alone" (harness-ui-carry--flow '("alone") 4 10)))))

(ert-deftest harness-ui-carry-panel-breaks-for-a-buffer-that-truncates ()
  "With `:width' the wording of a choice breaks between its segments, so a
buffer that truncates its lines (the session list) shows all of it."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (let ((lines (harness-ui-carry-test--lines
                (harness-ui-carry-panel-string (harness-ui-carry-test--spec :width 80)))))
    (should (cl-every (lambda (l) (<= (string-width l) 80)) lines))
    ;; The first line of the wording follows the cost; the others are under it,
    ;; broken between segments and never inside one.
    (should (member "    b  Brief summary    ~$0.0040  Cheap · narrative, tool calls in brief" lines))
    (should (member (concat (make-string 34 ?\s) "first and last messages kept · default") lines))
    ;; Wide enough, nothing breaks.
    (should (member "    b  Brief summary    ~$0.0040  Cheap · narrative, tool calls in brief · first and last messages kept · default"
                    (harness-ui-carry-test--lines
                     (harness-ui-carry-panel-string (harness-ui-carry-test--spec :width 200)))))))

(ert-deftest harness-ui-carry-keymap-answers ()
  "A choice's key answers with its name, its capital answers always -- not
for not now, and not at all unless the spec says `:always' -- and a keymap
under it stays under it."
  (let ((answers nil)
        (parent (make-sparse-keymap)))
    (define-key parent "1" #'ignore)
    (let ((map (harness-ui-carry-keymap
                (harness-ui-carry-test--spec :always t :answer (lambda (name always) (push (list name always) answers)))
                parent)))
      (dolist (key '("b" "s" "t" "q" "B" "T"))
        (call-interactively (lookup-key map key)))
      (should (equal '(("brief" nil) ("summary" nil) ("transcript" nil) ("hold" nil)
                       ("brief" t) ("transcript" t))
                     (reverse answers)))
      (should-not (lookup-key map "Q"))
      (should-not (lookup-key map "c"))
      (should (eq (keymap-parent map) parent)))
    (let ((map (harness-ui-carry-keymap (harness-ui-carry-test--spec :answer #'ignore))))
      (should (commandp (lookup-key map "b")))
      (should-not (lookup-key map "B")))))

(ert-deftest harness-ui-carry-buttons-answer-a-click ()
  "The button of a choice answers on a click, and RET: it calls the spec's answer."
  (harness-test-reset-bus)
  (harness-test-load-module 'ui)
  (let* ((answers nil)
         (string (harness-ui-carry-panel-string
                  (harness-ui-carry-test--spec :answer (lambda (name always) (push (list name always) answers))))))
    (with-temp-buffer
      (insert string)
      (goto-char (1+ (string-search "Transcript file" string)))
      (harness-ui-action-push))
    (should (equal '(("transcript" nil)) answers))))

;;;; Hosts

(define-derived-mode harness-ui-carry-test-mode special-mode "Carry-test"
  "A buffer that shows the panel of a question, to test hosting with.")

(defun harness-ui-carry-test--redraw ()
  "Draw this buffer again: the panel of its question, if any."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert "top\n")
    (insert (or (harness-ui-carry-panel) ""))
    (insert "bottom\n")))

(defmacro harness-ui-carry-test-with-host (&rest body)
  "Run BODY with a buffer `host' that shows the panel of a question, a host."
  (declare (indent 0))
  `(progn
     (harness-test-reset-bus)
     (harness-test-load-module 'ui)
     (let ((harness-ui-carry-hosts '((harness-ui-carry-test-mode . harness-ui-carry-test--redraw)))
           (host (generate-new-buffer " *carry-host*")))
       (unwind-protect
           (progn
             (with-current-buffer host (harness-ui-carry-test-mode) (harness-ui-carry-test--redraw))
             ,@body)
         (kill-buffer host)))))

(defun harness-ui-carry-test--press (buffer key)
  "Press KEY with point on the panel of BUFFER."
  (with-current-buffer buffer
    (goto-char (harness-ui-carry-position))
    (call-interactively (key-binding (kbd key)))))

(ert-deftest harness-ui-carry-show-asks-until-it-is-answered ()
  "A question shown in a host draws its panel there; its key answers it,
once: the panel goes and the callback gets the name of the choice.  A
second press, of a panel drawn before, answers nothing."
  (harness-ui-carry-test-with-host
    (let ((answers nil))
      (should (harness-ui-carry-host-p host))
      (should-not (harness-ui-carry-host-p (current-buffer)))
      (should (harness-ui-carry-show host "ask" (lambda () (harness-ui-carry-test--spec))
                                     (lambda (name) (push name answers))))
      (with-current-buffer host
        (should harness-ui-carry--prompt)
        (should (string-match-p "^top\n.*Something cold" (buffer-string)))
        (should (string-match-p "bottom\n\\'" (buffer-string))))
      ;; The panel's key; a stale copy of the command answers nothing a second time.
      (let ((command (with-current-buffer host
                       (goto-char (harness-ui-carry-position))
                       (key-binding (kbd "t")))))
        (call-interactively command)
        (should (equal '("transcript") answers))
        (with-current-buffer host
          (should-not harness-ui-carry--prompt)
          (should-not (harness-ui-carry-position))
          (should-not (string-match-p "Something cold" (buffer-string))))
        (call-interactively command)
        (should (equal '("transcript") answers))))))

(ert-deftest harness-ui-carry-show-replaces-the-question-it-replaces ()
  "A question asked in a host that asks one already replaces it: the first
is never answered, though its panel's key was pressed after."
  (harness-ui-carry-test-with-host
    (let ((answers nil))
      (harness-ui-carry-show host "first" (lambda () (harness-ui-carry-test--spec :id "first"))
                             (lambda (name) (push (list 'first name) answers)))
      (let ((stale (with-current-buffer host
                     (goto-char (harness-ui-carry-position))
                     (key-binding (kbd "b")))))
        (harness-ui-carry-show host "second" (lambda () (harness-ui-carry-test--spec :id "second"))
                               (lambda (name) (push (list 'second name) answers)))
        (call-interactively stale)
        (should-not answers)
        (harness-ui-carry-test--press host "s")
        (should (equal '((second "summary")) answers))))))

(ert-deftest harness-ui-carry-the-spec-is-made-again-each-time-it-is-drawn ()
  "The spec of a question is made whenever its panel is drawn, so it says what is
true then: what a choice costs, what the cache is."
  (harness-ui-carry-test-with-host
    (let ((cost "~$0.010"))
      (harness-ui-carry-show host "ask"
                             (lambda ()
                               (harness-ui-carry-test--spec
                                :choices (list (harness-carry-choice 'summary :cost-text cost)
                                               (harness-carry-choice 'hold))))
                             #'ignore)
      (with-current-buffer host
        (should (string-match-p "~\\$0\\.010" (buffer-string)))
        (setq cost "~$0.100")
        (harness-ui-carry-test--redraw)
        (should (string-match-p "~\\$0\\.100" (buffer-string)))
        (should-not (string-match-p "~\\$0\\.010" (buffer-string)))))))

(ert-deftest harness-ui-carry-point-goes-to-the-panel-where-the-host-shows ()
  "Where a window shows the host, point goes to the panel when it is drawn,
so its keys work; where none does, the echo area says where to answer."
  (harness-ui-carry-test-with-host
    (let ((said nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (when format-string (push (apply #'format format-string args) said)))))
        (harness-ui-carry-show host "ask" (lambda () (harness-ui-carry-test--spec)) #'ignore)
        (should (string-match-p "Choose how to carry the conversation over in  \\*carry-host\\*" (car said)))
        (setq said nil)
        (save-window-excursion
          (set-window-buffer (selected-window) host)
          (harness-ui-carry-show host "again" (lambda () (harness-ui-carry-test--spec)) #'ignore)
          (should-not said)
          (with-current-buffer host
            (should (= (point) (harness-ui-carry-position)))
            (should (harness-ui-carry-on-panel-p))
            (should (= (window-point (get-buffer-window host)) (harness-ui-carry-position)))))))))

(ert-deftest harness-ui-carry-hint-only-where-the-host-has-a-compose-box ()
  "The line saying how to press a key from the compose box is the panel's
only where the host has a box."
  (harness-ui-carry-test-with-host
    (harness-ui-carry-show host "ask" (lambda () (harness-ui-carry-test--spec)) #'ignore)
    (with-current-buffer host
      (should-not (string-match-p "from the box" (buffer-string)))
      (cl-letf (((symbol-function 'harness-compose-live-p) (lambda () t)))
        (harness-ui-carry-test--redraw))
      (should (string-match-p "from the box: C-c \\. b" (buffer-string))))))

(ert-deftest harness-ui-carry-host-picks-the-buffer-the-command-ran-in ()
  "The question shows in the buffer the command ran in, if that can host it;
else in the session's own chat; else in the session list, shown for it.
Never nowhere, and never the minibuffer."
  (harness-ui-carry-test-with-host
    (let ((chat (generate-new-buffer " *carry-chat*"))
          (list (generate-new-buffer " *carry-list*"))
          (shown 0))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'harness-chat--buffer-for)
                       (lambda (sid) (and (equal sid "s1") chat)))
                      ((symbol-function 'harness-sessions) (lambda (&rest _) (cl-incf shown)))
                      ((symbol-function 'read-multiple-choice)
                       (lambda (&rest _) (error "The question asked in the minibuffer"))))
              (with-current-buffer chat (harness-ui-carry-test-mode))
              (with-current-buffer list (harness-ui-carry-test-mode))
              (let ((harness-ui-sessions--buffer-name (buffer-name list)))
                ;; The buffer the command ran in wins, a session's chat or not.
                (should (eq host (harness-ui-carry-host "s1" host)))
                (should (eq host (harness-ui-carry-host nil host)))
                (should (= 0 shown))
                ;; Not a host: the session's chat.
                (should (eq chat (harness-ui-carry-host "s1" (current-buffer))))
                (should (eq chat (harness-ui-carry-host "s1" nil)))
                ;; No chat either, or a batch: the session list, opened.
                (should (eq list (harness-ui-carry-host "s2" (current-buffer))))
                (should (= 1 shown))
                (should (eq list (harness-ui-carry-host nil nil)))
                (should (= 2 shown))
                (should (eq list (harness-ui-carry-host nil (get-buffer-create " *not a host*")))))))
        (kill-buffer chat)
        (kill-buffer list)
        (when (get-buffer " *not a host*") (kill-buffer " *not a host*"))))))

(ert-deftest harness-ui-carry-hosts-are-the-chat-the-list-and-the-board ()
  "The chat, the session list and the task board can host a question, each
through the hook that draws its panels, which the module adds the panel to."
  (should (equal '(harness-chat-mode harness-ui-tasks-mode harness-ui-sessions-mode)
                 (mapcar #'car (default-value 'harness-ui-carry-hosts))))
  (let ((harness-chat-panel-functions nil)
        (harness-ui-sessions-panel-functions nil)
        (harness-ui-tasks-panel-functions nil))
    (harness-ui-carry--init)
    (dolist (hook '(harness-chat-panel-functions harness-ui-sessions-panel-functions
                    harness-ui-tasks-panel-functions))
      (should (memq #'harness-ui-carry-panel (symbol-value hook))))))

(ert-deftest harness-ui-carry-an-unanswered-question-dies-with-its-buffer ()
  "A host killed before the answer takes the question with it; a key pressed
on a panel that outlived it, in a copy of its text, answers nothing."
  (let ((answers nil) command)
    (harness-ui-carry-test-with-host
      (harness-ui-carry-show host "ask" (lambda () (harness-ui-carry-test--spec))
                             (lambda (name) (push name answers)))
      (setq command (with-current-buffer host
                      (goto-char (harness-ui-carry-position))
                      (key-binding (kbd "t")))))
    (call-interactively command)
    (should-not answers)))

(provide 'harness-ui-carry-test)
;;; harness-ui-carry-test.el ends here
