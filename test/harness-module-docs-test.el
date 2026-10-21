;;; harness-module-docs-test.el --- Module pages read from the source  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness.

;;; Commentary:

;; harness-module-docs.el reads what a module provides and uses from its
;; source.  These tests read fixture modules written for each construct,
;; generate their pages twice, and read the harness's own tree.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-module-docs)

(defconst harness-module-docs-test--alpha
  ";;; harness-alpha.el --- Alpha  -*- lexical-binding: t; -*-

;;; Commentary:

;; Alpha keeps `the-things' that beta fetches.
;;
;; A second paragraph.

;;; Code:

(require 'harness-core)
(require 'harness-beta)
(require 'subr-x)

(defvar harness-alpha-changed-hook nil
  \"Hook run after alpha changes.\")

(defvar harness-alpha--cache nil \"Internal, no option.\")

(defcustom harness-alpha-size 3
  \"How big alpha grows.
More lines.\"
  :type 'integer)

(harness-declare-event 'alpha/changed \"(ID) after alpha changes.\")

(dolist (e '((alpha/opened . \"(ID) when alpha opens.\")
             (alpha/closed . \"(ID) when alpha closes.\")))
  (harness-declare-event (car e) (cdr e)))

(add-to-list 'harness-acp-extra-events 'alpha/changed)

(harness-defmethod alpha/get (id &optional fresh)
  \"Return alpha ID, fetched again with FRESH.\"
  (harness-call 'beta/fetch id fresh))

(harness-register-method 'alpha/raw #'ignore :doc \"Raw alpha.\")

(harness-define-tool \"alpha_tool\"
  :label \"Alpha\"
  :description \"Grow alpha.
Then shrink it.\"
  :handler #'ignore)

(harness-define-provider 'alpha-llm :label \"Alpha LLM\" :doc \"Models of alpha.\")

(defun harness-alpha--on-turn (session)
  \"Note SESSION's turn.\"
  (harness-emit 'alpha/changed session))

(defun harness-alpha-show ()
  \"Show alpha.\"
  (interactive)
  (harness-call 'alpha/raw)
  (harness-call-async 'beta/list))

(defun harness-alpha-internal-command ()
  \"Not interactive, so no command.\"
  nil)

(defun harness-alpha--init ()
  \"Wire alpha in.\"
  (harness-on 'agent/turn-ended #'harness-alpha--on-turn 30)
  (dolist (ev '(session/created session/deleted))
    (harness-on ev #'harness-alpha--on-turn))
  (harness-on 'alpha/opened (lambda (&rest _) nil))
  (harness-add-filter 'agent/system-prompt #'harness-alpha--prompt 60)
  (add-hook 'kill-emacs-hook #'harness-alpha--save)
  (when (harness-method-exists-p 'gamma/ping)
    (harness-call 'gamma/ping))
  (harness-run-filter 'alpha/choose nil)
  (harness-run-filter-async-traced 'alpha/decide nil (list 1)))

(harness-define-module 'alpha
  :doc \"The alpha module, for `testing'.\"
  :requires '(beta)
  :init #'harness-alpha--init)

(provide 'harness-alpha)
;;; harness-alpha.el ends here
")

(defconst harness-module-docs-test--beta
  ";;; harness-beta.el --- Beta  -*- lexical-binding: t; -*-
;;; Code:
(require 'harness-core)
(harness-defmethod beta/fetch (id &optional _fresh) \"Fetch ID.\" id)
(harness-defmethod beta/list () \"List them all.\" nil)
(defun harness-beta--init ()
  (harness-add-filter 'alpha/choose #'identity 10))
(harness-define-module 'beta :doc \"Beta, which alpha needs.\" :init #'harness-beta--init)
(provide 'harness-beta)
")

(defconst harness-module-docs-test--ui-alpha
  ";;; harness-ui-alpha.el --- Alpha's UI  -*- lexical-binding: t; -*-
;;; Code:
(require 'harness-ui)
(defun harness-ui-alpha--on-event (event _args)
  \"Redraw after EVENT.\"
  (cond ((equal event \"alpha/changed\") (harness-ui-alpha--redraw))
        ((string-prefix-p \"session/\" event) (harness-ui-alpha--redraw))
        ((equal event \"alpha/never\") nil)))
(defun harness-ui-alpha--fetch ()
  (harness-ui-request \"_harness/alpha/get\" (list :id 1)))
(defun harness-ui-alpha--init ()
  (add-hook 'harness-ui-event-functions #'harness-ui-alpha--on-event))
(harness-define-module 'ui-alpha :doc \"Alpha's buffer.\" :requires '(ui) :init #'harness-ui-alpha--init)
(provide 'harness-ui-alpha)
")

(defconst harness-module-docs-test--library
  ";;; harness-alpha-lib.el --- Not a module  -*- lexical-binding: t; -*-
;;; Code:
(defun harness-alpha-lib-helper () (harness-emit 'alpha/changed 1))
(provide 'harness-alpha-lib)
")

(defmacro harness-module-docs-test-with-tree (&rest body)
  "Run BODY with `harness-directory' a temporary tree of the fixture modules.
The tree has lisp/modules/harness-alpha.el, harness-beta.el and
harness-alpha-lib.el, and lisp/ui/harness-ui-alpha.el; `tree' is bound
to it in BODY."
  (declare (indent 0))
  `(let* ((tree (harness-test-temp-dir))
          (harness-directory tree)
          (harness-module-directories '("lisp/modules" "lisp/ui"))
          (harness-extra-module-directories nil))
     (make-directory (expand-file-name "lisp/modules" tree) t)
     (make-directory (expand-file-name "lisp/ui" tree) t)
     (dolist (f `(("lisp/modules/harness-alpha.el" . ,harness-module-docs-test--alpha)
                  ("lisp/modules/harness-beta.el" . ,harness-module-docs-test--beta)
                  ("lisp/modules/harness-alpha-lib.el" . ,harness-module-docs-test--library)
                  ("lisp/ui/harness-ui-alpha.el" . ,harness-module-docs-test--ui-alpha)))
       (with-temp-file (expand-file-name (car f) tree) (insert (cdr f))))
     (unwind-protect (progn ,@body)
       (delete-directory tree t))))

(defun harness-module-docs-test--read (file)
  "Return the contents of FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(ert-deftest harness-module-docs-scan-reads-what-a-module-provides-and-uses ()
  "Every construct of the fixture is read from its source, without loading it."
  (harness-module-docs-test-with-tree
    (let ((scan (harness-module-docs-scan (expand-file-name "lisp/modules/harness-alpha.el" tree))))
      (should-not (featurep 'harness-alpha))
      (should (eq (plist-get scan :name) 'alpha))
      (should (equal (plist-get scan :doc) "The alpha module, for `testing'."))
      (should (equal (plist-get scan :requires) '(beta)))
      (should-not (plist-get scan :ui))
      (should (equal (plist-get scan :file-requires) '(beta core)))
      (should (equal (plist-get scan :commentary)
                     "Alpha keeps `the-things' that beta fetches.\n\nA second paragraph."))
      (should (equal (mapcar #'car (plist-get scan :methods)) '(alpha/get alpha/raw)))
      (should (equal (cdr (assq 'alpha/get (plist-get scan :methods)))
                     '(:args (id &optional fresh) :doc "Return alpha ID, fetched again with FRESH.")))
      (should (equal (plist-get scan :tools) '(("alpha_tool" . "Grow alpha.\nThen shrink it."))))
      (should (equal (plist-get scan :providers) '((alpha-llm . "Models of alpha."))))
      ;; Declared by name, and through a dolist over a quoted list.
      (should (equal (plist-get scan :events)
                     '((alpha/changed . "(ID) after alpha changes.")
                       (alpha/closed . "(ID) when alpha closes.")
                       (alpha/opened . "(ID) when alpha opens."))))
      (should (equal (plist-get scan :emits) '(alpha/changed)))
      (should (equal (plist-get scan :forwards) '(alpha/changed)))
      (should (equal (plist-get scan :handles)
                     '((agent/turn-ended harness-alpha--on-turn 30)
                       (alpha/opened "lambda" nil)
                       (session/created harness-alpha--on-turn nil)
                       (session/deleted harness-alpha--on-turn nil))))
      (should (equal (plist-get scan :filters-joined)
                     '((agent/system-prompt harness-alpha--prompt 60))))
      ;; Run plainly, and traced (as the permission chain is).
      (should (equal (plist-get scan :filters-run) '(alpha/choose alpha/decide)))
      (should (equal (plist-get scan :calls) '(alpha/raw beta/fetch beta/list gamma/ping)))
      (should (equal (plist-get scan :checks) '(gamma/ping)))
      (should (equal (plist-get scan :hooks-defined)
                     '((harness-alpha-changed-hook . "Hook run after alpha changes."))))
      (should (equal (plist-get scan :hooks-used) '((kill-emacs-hook harness-alpha--save))))
      (should (equal (plist-get scan :options)
                     '((harness-alpha-size . "How big alpha grows.\nMore lines."))))
      (should (equal (plist-get scan :commands) '((harness-alpha-show . "Show alpha.")))))))

(ert-deftest harness-module-docs-scan-reads-a-ui-module ()
  "A UI module's events are those its handler on the UI event hook compares with."
  (harness-module-docs-test-with-tree
    (let ((scan (harness-module-docs-scan (expand-file-name "lisp/ui/harness-ui-alpha.el" tree))))
      (should (eq (plist-get scan :name) 'ui-alpha))
      (should (plist-get scan :ui))
      (should (equal (plist-get scan :calls) '(alpha/get)))
      (should (equal (plist-get scan :ui-events)
                     '((alpha/changed harness-ui-alpha--on-event)
                       (alpha/never harness-ui-alpha--on-event)
                       (session/* harness-ui-alpha--on-event)))))))

(ert-deftest harness-module-docs-scan-skips-what-is-no-module ()
  "A library defines no module; a file that does not read says why."
  (harness-module-docs-test-with-tree
    (should-not (harness-module-docs-scan (expand-file-name "lisp/modules/harness-alpha-lib.el" tree)))
    (let ((bad (expand-file-name "lisp/modules/harness-bad.el" tree)))
      (with-temp-file bad (insert "(harness-define-module 'bad)\n(foo . . bar)\n"))
      (should (plist-get (harness-module-docs-scan bad) :error))
      (should-not (cl-find 'bad (harness-module-docs-collect) :key (lambda (s) (plist-get s :name)))))))

(ert-deftest harness-module-docs-scan-reads-a-changed-file-again ()
  "The scan of a file is kept until the file changes."
  (harness-module-docs-test-with-tree
    (let ((file (expand-file-name "lisp/modules/harness-beta.el" tree)))
      (should (equal (plist-get (harness-module-docs-scan file) :doc) "Beta, which alpha needs."))
      (with-temp-file file
        (insert (replace-regexp-in-string "which alpha needs" "changed" harness-module-docs-test--beta)))
      (set-file-times file (time-add (current-time) 5))
      (should (equal (plist-get (harness-module-docs-scan file) :doc) "Beta, changed.")))))

(ert-deftest harness-module-docs-collect-links-the-modules ()
  "Who requires a module, and which module defines the methods another calls."
  (harness-module-docs-test-with-tree
    (let* ((all (harness-module-docs-collect))
           (get (lambda (name) (cl-find name all :key (lambda (s) (plist-get s :name))))))
      (should (equal (mapcar (lambda (s) (plist-get s :name)) all) '(alpha beta ui-alpha)))
      (should (equal (plist-get (funcall get 'beta) :required-by) '(alpha)))
      (should (equal (plist-get (funcall get 'alpha) :owners)
                     '((alpha/raw . alpha) (beta/fetch . beta) (beta/list . beta))))
      (should (equal (plist-get (funcall get 'ui-alpha) :owners) '((alpha/get . alpha))))
      (should (equal (harness-module-docs-hearers all 'session/created) '(alpha)))
      (should (equal (harness-module-docs-hearers all 'alpha/changed) '(ui-alpha)))
      (should (harness-module-docs-reaches-ui-p all 'alpha/changed))
      (should-not (harness-module-docs-reaches-ui-p all 'alpha/never)))))

(ert-deftest harness-module-docs-pages-say-what-modules-provide-and-use ()
  "A page has the module's doc, its requirements, interfaces and events, linked."
  (harness-module-docs-test-with-tree
    (let* ((all (harness-module-docs-collect))
           (alpha (harness-module-docs-page (car all) all))
           (beta (harness-module-docs-page (nth 1 all) all))
           (ui (harness-module-docs-page (nth 2 all) all)))
      (should (string-prefix-p harness-module-docs-header alpha))
      (dolist (text '("# alpha\n\nThe alpha module, for `testing`."
                      "**Runs in:** the harness process"
                      "**Requires:** [beta](beta.md)"
                      "## About\n\nAlpha keeps `the-things` that beta fetches."
                      "- `alpha/get` (id &optional fresh) — Return alpha ID, fetched again with FRESH."
                      "- `alpha_tool` — Grow alpha."
                      "- `alpha-llm` — Models of alpha."
                      "- `alpha/changed` — (ID) after alpha changes."
                      "- `alpha/choose`"
                      "- `harness-alpha-changed-hook` — Hook run after alpha changes."
                      "- `harness-alpha-show` — Show alpha."
                      "- `harness-alpha-size` — How big alpha grows."
                      "- `beta/fetch` ([beta](beta.md))"
                      "- `gamma/ping`, when it is loaded"
                      "- `agent/turn-ended` → `harness-alpha--on-turn` at 30"
                      "- `session/created` → `harness-alpha--on-turn`\n"
                      "- `agent/system-prompt` at 60 → `harness-alpha--prompt`"
                      "- `kill-emacs-hook` → `harness-alpha--save`"))
        (should (string-search text alpha)))
      ;; A call of its own method is no use of another module.
      (should-not (string-search "alpha/raw" (cadr (split-string alpha "## Uses\n"))))
      (should (string-search "**Required by:** [alpha](alpha.md)" beta))
      (should (string-search "- `alpha/choose` at 10 → `identity`" beta))
      (should (string-search "**Runs in:** the UI (your Emacs)" ui))
      (should (string-search "- `alpha/get` ([alpha](alpha.md))" ui))
      (should (string-search "- `alpha/changed` → `harness-ui-alpha--on-event`\n" ui))
      (should (string-search "- `alpha/never` → `harness-ui-alpha--on-event` (never forwarded to the UI)" ui)))))

(ert-deftest harness-module-docs-generate-writes-pages-again-only-when-they-change ()
  "One call writes every page and the index; the output is stable, stale pages go."
  (harness-module-docs-test-with-tree
    (let* ((out (expand-file-name "docs/modules" tree))
           (written (harness-module-docs-generate out))
           (index (expand-file-name "README.md" out)))
      (should (equal (mapcar #'file-name-nondirectory written)
                     '("alpha.md" "beta.md" "ui-alpha.md" "README.md")))
      (let ((text (harness-module-docs-test--read index)))
        (dolist (row '("| [alpha](alpha.md) |"
                       "| `alpha/changed` | [alpha](alpha.md) | [alpha](alpha.md) | [ui-alpha](ui-alpha.md) | yes |"
                       "| `session/created` |  |  | [alpha](alpha.md) |  |"
                       "| `alpha/choose` | [alpha](alpha.md) | [beta](beta.md) (10) |"
                       "| `kill-emacs-hook` |  | [alpha](alpha.md) |"))
          (should (string-search row text)))
        ;; The UI module's prefix matches the forwarded events only.
        (should-not (string-search "| `session/*`" text)))
      ;; A page of a module that is gone is deleted; a page written by
      ;; hand is kept.
      (with-temp-file (expand-file-name "gone.md" out)
        (insert harness-module-docs-header "\n\n# gone\n"))
      (with-temp-file (expand-file-name "guide.md" out) (insert "# A guide\n"))
      (let ((before (mapcar (lambda (f) (cons f (harness-module-docs-test--read f))) written))
            (times (mapcar (lambda (f) (file-attribute-modification-time (file-attributes f))) written)))
        (sleep-for 0.01)
        (should (equal (harness-module-docs-generate out) written))
        (dolist (f before) (should (equal (harness-module-docs-test--read (car f)) (cdr f))))
        ;; Unchanged pages are not written again.
        (should (equal (mapcar (lambda (f) (file-attribute-modification-time (file-attributes f))) written)
                       times)))
      (should-not (file-exists-p (expand-file-name "gone.md" out)))
      (should (file-exists-p (expand-file-name "guide.md" out))))))

(ert-deftest harness-module-docs-describe-module-shows-its-page ()
  "\\[harness-describe-module] shows a module's page in a help buffer.
Rendered, a link to another module describes that one; without the
UI's Markdown renderer the page is Markdown.  Neither has the comment
generated files start with."
  (require 'harness-ui-markdown)
  (harness-module-docs-test-with-tree
    (let ((buffers '("*harness-module beta*" "*harness-module alpha*")))
      (unwind-protect
          (save-window-excursion
            (harness-describe-module 'beta)
            (with-current-buffer "*harness-module beta*"
              (should-not (string-search "Generated by" (buffer-string)))
              (should (string-prefix-p "beta\n" (buffer-string)))
              (should (string-search "Beta, which alpha needs." (buffer-string)))
              (should (equal (file-name-as-directory tree) default-directory))
              (goto-char (point-min))
              (should (search-forward "Required by:" nil t))
              (let ((link (text-property-any (point) (point-max) 'harness-module 'alpha)))
                (should link)
                (goto-char link)
                (harness-module-docs-follow-link)))
            (with-current-buffer "*harness-module alpha*"
              (should (string-prefix-p "alpha\n\nThe alpha module, for testing." (buffer-string))))
            (cl-letf (((symbol-function 'harness-ui-markdown-render) nil))
              (harness-describe-module 'beta)
              (with-current-buffer "*harness-module beta*"
                (should (string-prefix-p "# beta\n" (buffer-string)))
                (should (string-search "**Required by:** [alpha](alpha.md)" (buffer-string))))))
        (dolist (b buffers) (when (get-buffer b) (kill-buffer b))))
      (should-error (harness-describe-module 'nothing) :type 'user-error))))

(ert-deftest harness-module-docs-reads-the-harness-modules ()
  "Each of the harness's own module files defines the module its name says.
It reads, and every module it requires is one of the harness's."
  (let* ((files (harness-module-docs-files))
         (all (harness-module-docs-collect))
         (names (mapcar (lambda (s) (plist-get s :name)) all)))
    (should (> (length all) 50))
    (dolist (file files)
      (let ((scan (harness-module-docs-scan file)))
        (should-not (plist-get scan :error))
        (when scan
          (should (eq (plist-get scan :name) (harness--file-module-name file))))))
    (dolist (s all)
      (should (plist-get s :doc))
      (dolist (r (plist-get s :requires))
        (should (memq r names))))
    ;; The loader declares and emits the lifecycle events; the index says so.
    (should (string-search "| `harness/started` | `harness.el` | `harness.el` |"
                           (harness-module-docs-index all)))))

(ert-deftest harness-module-docs-events-are-declared-and-reach-their-hearers ()
  "Every event the harness emits is declared, and every one the UI hears reaches it.
An event emitted without `harness-declare-event' is on no page, and a UI
module that hears an event the ACP server does not forward hears nothing."
  (let* ((every (append (harness-module-docs-collect) (harness-module-docs-core-scans)))
         (declared (cl-loop for s in every append (mapcar #'car (plist-get s :events))))
         (undeclared nil)
         (unheard nil))
    (dolist (s every)
      (dolist (event (plist-get s :emits))
        (unless (memq event declared)
          (push (cons (plist-get s :name) event) undeclared)))
      (dolist (heard (plist-get s :ui-events))
        (let ((event (car heard)))
          (unless (if (string-suffix-p "/*" (symbol-name event))
                      (harness-module-docs-reaches-ui-p every event)
                    (harness-module-docs-forwarded-p every event))
            (push (cons (plist-get s :name) event) unheard)))))
    (should-not undeclared)
    (should-not unheard)))

(provide 'harness-module-docs-test)
;;; harness-module-docs-test.el ends here
