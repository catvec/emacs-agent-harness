;;; harness-ui-config.el --- The settings page  -*- lexical-binding: t; -*-

;;; Commentary:

;; `harness-settings' (C-c h S) shows every setting of the harness on
;; one page, like a customize buffer, with a scope toggle at the top:
;;
;;   Global   the customize value, used everywhere unless a project
;;            overrides it, saved in the custom file;
;;   Project  the .dir-locals.el at the root of the project of the
;;            current buffer (in a chat buffer: of the session's working
;;            directory), which overrides the global value there.
;;
;; The page leads with the settings most people change, in the sections
;; the harness names (`harness-config-sections'): new sessions, files
;; and safety, the task board, notifications, models and services.
;; Everything else is advanced: the Global scope folds it into one line
;; saying how many there are and how many were changed, and `a' (or the
;; button there) shows them, by module.  The Project scope shows only
;; the settings that layer (model, permission mode, thinking, allowed
;; directories, budget, sandbox policy, non-interactive, task files),
;; in their sections, and folds the rest, which have a global value
;; only, into one line.  The options of the interface itself live in
;; this Emacs, not the harness: a button at the end opens Customize on
;; them.
;;
;; Each setting is a `wid-edit' widget built from the option's customize
;; type, its documentation, and a line saying where the value in effect
;; here comes from (global, project or a directory below the root).
;; Toggles and menus save at once; text, numbers and lists save with
;; RET or C-c C-c, and C-x C-s saves every edit of the scope.  In the
;; Project scope an overridden setting offers [Remove override]; in the
;; Global scope a customized one offers [Reset to default].  Secrets
;; never reach the page: they show as set or not, and are set through
;; `read-passwd'.  Long texts (prompts) are edited in `string-edit'.
;;
;; Records (a plist whose type names its keys, like a model endpoint)
;; show as forms: a line for each key the type knows, with its name, a
;; value of its own type and a line of help, ticked when the record has
;; it and otherwise greyed out with the value it would start from.  In
;; a list, each record folds into a line that sums it up, [Edit] opens
;; it and [Hide] folds it again; a record added with [INS] starts open,
;; from the type's starting value.  See `harness-ui-config--present'.
;;
;; The page computes nothing itself.  It asks the harness with
;; `_harness/config/describe', saves with `_harness/config/set' and
;; `_harness/config/unset' (values travel printed, so JSON keeps their
;; types), and reloads after every `config/changed' event, keeping edits
;; not saved yet and point.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'text-property-search)
(require 'wid-edit)
(require 'cus-edit)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(declare-function string-edit "string-edit")

(defgroup harness-ui-config nil
  "The settings page." :group 'harness-ui)

(defconst harness-ui-config--default-scope 'global
  "Scope the settings page opens in: `global' or `project'.")

(defface harness-settings-title-face '((t :inherit bold :height 1.3))
  "The title of the settings page." :group 'harness-ui-config)
(defface harness-settings-heading-face '((t :inherit bold :height 1.1))
  "Section headings of the settings page." :group 'harness-ui-config)
(defface harness-settings-label-face '((t :inherit bold))
  "Names of settings." :group 'harness-ui-config)
(defface harness-settings-doc-face '((t :inherit shadow))
  "Documentation and explanations on the settings page." :group 'harness-ui-config)
(defface harness-settings-global-face '((t :inherit (font-lock-type-face bold)))
  "A value set globally." :group 'harness-ui-config)
(defface harness-settings-project-face '((t :inherit (font-lock-keyword-face bold)))
  "A value set for the project." :group 'harness-ui-config)
(defface harness-settings-directory-face '((t :inherit (font-lock-constant-face bold)))
  "A value set for a directory below the project root." :group 'harness-ui-config)
(defface harness-settings-edited-face '((t :inherit (warning bold)))
  "A setting edited but not saved." :group 'harness-ui-config)
(defface harness-settings-selected-face '((t :inherit (bold highlight)))
  "The scope shown, in the header line." :group 'harness-ui-config)

(defconst harness-ui-config--module-titles
  '(("config" . "Session defaults") ("agent" . "Agent") ("compaction" . "Compaction")
    ("merge" . "Merge queue") ("naming" . "Session naming") ("perms" . "Permissions")
    ("provider" . "Models") ("provider-claude" . "Claude Code") ("provider-copilot" . "GitHub Copilot")
    ("provider-openai" . "OpenAI-compatible providers") ("provider-bedrock" . "AWS Bedrock")
    ("provider-demo" . "Demo provider")
    ("sandbox" . "Sandbox") ("session" . "Sessions") ("skills" . "Skills") ("tasks" . "Task mode")
    ("tools" . "Tools") ("tools-fs" . "File tools") ("tools-sessions" . "Session tools")
    ("tools-shell" . "Shell tools") ("tools-web" . "Web tools") ("tools-agent" . "Agent tools")
    ("tools-emacs" . "Emacs tools") ("usage" . "Usage and budgets") ("worktree" . "Worktrees")
    ("core" . "Core"))
  "Section titles of the harness modules.")

(defconst harness-ui-config--labels nil
  "Names of settings that the general rule gets wrong, as (KEY . NAME).")

(defconst harness-ui-config--acronyms
  '("api" "acp" "http" "ttl" "url" "ui" "id" "llm" "json" "usd" "fs" "btw" "aws")
  "Words written in capitals in the names of settings.")

;;;; Buffer state

(defvar-local harness-ui-config--cwd nil "Directory the page describes.")
(defvar-local harness-ui-config--root nil "Project root of that directory.")
(defvar-local harness-ui-config--scope 'global "Scope edited: `global' or `project'.")
(defvar-local harness-ui-config--data nil "The last `config/describe' answer.")
(defvar-local harness-ui-config--loading nil "Non-nil while the settings are being fetched.")
(defvar-local harness-ui-config--error nil "Message of the last failed fetch.")
(defvar-local harness-ui-config--generation 0 "Counter that drops stale answers.")
(defvar-local harness-ui-config--widgets nil "Alist of KEY and its setting widget, as drawn.")
(defvar-local harness-ui-config--show-advanced nil
  "Non-nil when the page shows the advanced settings, not just their count.")
(defvar-local harness-ui-config--edited nil
  "Hash of (SCOPE . KEY) for settings edited but not saved.
The value is t while the edit lives in the widget, or (VALUE) once a
redraw took it out of the widget.")
(defvar-local harness-ui-config--state nil
  "Hash of (SCOPE . KEY) to `saving' or (error . MESSAGE).")
(defvar-local harness-ui-config--overlays nil
  "Hash of KEY to the overlay showing its edit state.")
(defvar-local harness-ui-config--folds nil
  "The record widgets drawn on the page that fold (`harness-ui-config-fold').")
(defvar-local harness-ui-config--open-folds nil
  "Records open before the page was drawn again, as (KEY . VALUE).
A record of setting KEY whose value is VALUE is drawn open again.")
(defvar-local harness-ui-config--docs-shown nil
  "Keys of the settings whose whole documentation shows.")

(defvar harness-ui-config--drawing nil
  "Non-nil while the page draws its settings.
A record drawn then is open only when it was before; one added later,
with [INS], starts open.")

;;;; Values and types

(defun harness-ui-config--print (value)
  "Return VALUE printed for `config/set'."
  (let ((print-length nil) (print-level nil))
    (prin1-to-string value)))

(defun harness-ui-config--read (printed &optional default)
  "Return the value PRINTED stands for, or DEFAULT when it does not read."
  (if (stringp printed)
      (condition-case nil (car (read-from-string printed)) (error default))
    default))

(defun harness-ui-config--type (setting)
  "Return the customize type of SETTING."
  (harness-ui-config--read (plist-get setting :type) 'sexp))

(defun harness-ui-config--type-args (type)
  "Return the alternatives or elements of composite TYPE."
  (let ((rest (cdr-safe type)) out)
    (while rest
      (if (and (keywordp (car rest)) (cdr rest))
          (setq rest (cddr rest))
        (push (car rest) out)
        (setq rest (cdr rest))))
    (nreverse out)))

(defun harness-ui-config--choice-p (type)
  "Non-nil when TYPE picks one of several alternatives."
  (memq (car-safe type) '(choice radio menu-choice radio-button-choice)))

(defun harness-ui-config--discrete-p (type)
  "Non-nil when every value of TYPE is picked rather than typed."
  (or (memq (if (consp type) (car type) type) '(boolean toggle))
      (and (harness-ui-config--choice-p type)
           (let ((args (harness-ui-config--type-args type)))
             (and args (cl-every (lambda (a) (memq (car-safe a) '(const item))) args))))))

(defun harness-ui-config--fits-p (type value)
  "Non-nil when VALUE fits TYPE."
  (condition-case nil
      (widget-apply (widget-convert type) :match value)
    (error nil)))

(defun harness-ui-config--const-label (type value)
  "Return the name TYPE gives VALUE, when VALUE is one of its constants."
  (when (harness-ui-config--choice-p type)
    (cl-loop for arg in (harness-ui-config--type-args type)
             when (and (eq (car-safe arg) 'const) (cdr arg) (equal (car (last arg)) value))
             return (or (plist-get (cdr arg) :tag) (format "%s" value)))))

(defun harness-ui-config--show (value setting)
  "Return VALUE of SETTING the way the page writes it in a sentence."
  (let ((type (harness-ui-config--type setting)))
    (or (harness-ui-config--const-label type value)
        (cond ((eq type 'boolean) (if value "on" "off"))
              ((and (stringp value) (string-suffix-p "-model" (plist-get setting :key))
                    (string-search ":" value))
               (harness-ui-model-label value))
              ((null value) "none")
              ;; Records by name, rather than as Lisp.
              ((and (harness-ui-config--form-p type) (harness-ui-config--fits-p type value))
               (harness-truncate-end (harness-ui-config--short type value) 48))
              (t (harness-truncate-end
                  (replace-regexp-in-string "\n" " " (harness-ui-config--print value)) 48))))))

(defun harness-ui-config--scope-value (setting scope)
  "Return the value SETTING shows in SCOPE: the project's, else the global one."
  (harness-ui-config--read (or (and (eq scope 'project) (plist-get setting :project))
                               (plist-get setting :global))))

(defun harness-ui-config--true (value)
  "Non-nil when the wire VALUE is true."
  (harness-json-true-p value))

;;;; Names

(defun harness-ui-config--label (setting)
  "Return the display name of SETTING: harness-tasks-max-running is \"Max running\"."
  (let* ((key (plist-get setting :key))
         (module (or (plist-get setting :module) ""))
         (name (string-remove-prefix "harness-" key)))
    (or (cdr (assoc key harness-ui-config--labels))
        (progn
          (dolist (prefix (list (concat module "-")
                                (and (string-match "-\\([a-z]+\\)\\'" module)
                                     (concat (match-string 1 module) "-"))))
            (when (and prefix (string-prefix-p prefix name) (> (length name) (length prefix)))
              (setq name (substring name (length prefix)))))
          (let ((rest (split-string name "-" t)) words)
            (while rest
              (let ((w (pop rest)))
                (push (cond ((and (equal w "non") rest) (concat "non-" (pop rest))) ; non-interactive
                            ((member w harness-ui-config--acronyms) (upcase w))
                            (t w))
                      words)))
            (setq words (nreverse words))
            (when words
              (setcar words (concat (upcase (substring (car words) 0 1)) (substring (car words) 1))))
            (string-join words " "))))))

(defun harness-ui-config--module-title (module)
  "Return the section title of MODULE."
  (or (cdr (assoc module harness-ui-config--module-titles))
      (let ((words (replace-regexp-in-string "-" " " module)))
        (if (string-empty-p words) "Other"
          (concat (upcase (substring words 0 1)) (substring words 1))))))

(defun harness-ui-config--project-name ()
  "Return the name of the page's project."
  (or (plist-get harness-ui-config--data :project)
      (file-name-nondirectory (directory-file-name (or harness-ui-config--root harness-ui-config--cwd "")))))

(defun harness-ui-config--in-project-p ()
  "Non-nil when the page's directory is in a project (assumed until told)."
  (let ((v (plist-get harness-ui-config--data :in-project)))
    (or (null harness-ui-config--data) (harness-ui-config--true v))))

(defun harness-ui-config--place ()
  "Return what the Project scope is about: \"this project\" or \"this directory\"."
  (if (harness-ui-config--in-project-p) "this project" "this directory"))

(defun harness-ui-config--scope-label (scope)
  "Return the name of SCOPE on the toggle."
  (if (eq scope 'global) "Global"
    (if (harness-ui-config--in-project-p) "Project" "Directory")))

;;;; Edits

(defun harness-ui-config--edit-key (key &optional scope)
  "Return the key of KEY's edit in SCOPE (default: the page's)."
  (cons (or scope harness-ui-config--scope) key))

(defun harness-ui-config--edited-p (key)
  "Non-nil when KEY has an edit not saved in the page's scope."
  (gethash (harness-ui-config--edit-key key) harness-ui-config--edited))

(defun harness-ui-config--edit-count (&optional scope)
  "Return how many settings have edits not saved in SCOPE (default: the page's)."
  (let ((scope (or scope harness-ui-config--scope)) (n 0))
    (when harness-ui-config--edited
      (maphash (lambda (k _) (when (eq (car k) scope) (cl-incf n))) harness-ui-config--edited))
    n))

(defun harness-ui-config--widget (key)
  "Return the setting widget of KEY on the page, or nil."
  (cdr (assoc key harness-ui-config--widgets)))

(defun harness-ui-config--widget-value (widget)
  "Return the value WIDGET holds, or `invalid' when it holds none."
  (condition-case nil
      (if (widget-apply widget :validate) 'invalid (widget-value widget))
    (error 'invalid)))

(defun harness-ui-config--snapshot ()
  "Take the edits of the page's scope out of their widgets, before a redraw.
An edit that is not a valid value yet, such as \"12x\" in a number
field, is kept as it is: the widget shows it again.  Records open stay
open."
  (harness-ui-config--note-open-folds)
  (dolist (cell harness-ui-config--widgets)
    (let ((ekey (harness-ui-config--edit-key (car cell))))
      (when (eq t (gethash ekey harness-ui-config--edited))
        (condition-case nil
            (puthash ekey (list (widget-value (cdr cell))) harness-ui-config--edited)
          (error (remhash ekey harness-ui-config--edited)))))))

(defun harness-ui-config--state-of (key)
  "Return the save state of KEY in the page's scope."
  (gethash (harness-ui-config--edit-key key) harness-ui-config--state))

(defun harness-ui-config--set-state (key state &optional scope)
  "Record STATE (`saving', (error . MESSAGE) or nil) for KEY in SCOPE and show it."
  (let ((ekey (harness-ui-config--edit-key key scope)))
    (if state
        (puthash ekey state harness-ui-config--state)
      (remhash ekey harness-ui-config--state)))
  (harness-ui-config--show-state key))

(defun harness-ui-config--show-state (key)
  "Show the edit state of KEY in front of its status line."
  (when-let* ((ov (and harness-ui-config--overlays (gethash key harness-ui-config--overlays))))
    (when (overlay-buffer ov)
      (let ((state (harness-ui-config--state-of key)))
        (overlay-put ov 'before-string
                     (cond
                      ((eq state 'saving) (propertize "    saving\u2026" 'face 'harness-settings-doc-face))
                      ((eq (car-safe state) 'error)
                       (concat "    " (propertize (harness-ui-icon 'harness-icon-warning) 'face 'error) " "
                               (propertize (cdr state) 'face 'error)))
                      ((harness-ui-config--edited-p key)
                       (concat "    " (propertize "edited" 'face 'harness-settings-edited-face)
                               (propertize " \u00b7 RET or C-c C-c saves, C-c C-k reverts"
                                           'face 'harness-settings-doc-face)))
                      (t nil)))))
    (force-mode-line-update)))

;;;; The setting widget

(define-widget 'harness-ui-config-setting 'default
  "A setting on the harness settings page; its only child edits the value."
  :format "%v"
  :value-create #'harness-ui-config--setting-value-create
  :value-delete #'widget-children-value-delete
  :value-get #'harness-ui-config--setting-value-get
  :validate #'harness-ui-config--setting-validate
  :notify #'harness-ui-config--setting-notify)

(defun harness-ui-config--setting-value-create (widget)
  "Insert the child of setting WIDGET that edits its value."
  (widget-put widget :children
              (list (apply #'widget-create-child-and-convert
                           widget (widget-get widget :edit-type)
                           :tag (widget-get widget :tag)
                           :sample-face 'harness-settings-label-face
                           ;; List entries and their buttons line up with the doc.
                           :indent 4
                           :value (widget-get widget :value)
                           (widget-get widget :edit-args)))))

(defun harness-ui-config--setting-value-get (widget)
  "Return the value the child of setting WIDGET holds."
  (widget-value (car (widget-get widget :children))))

(defun harness-ui-config--setting-validate (widget)
  "Return the child of setting WIDGET that holds no valid value, or nil."
  (widget-apply (car (widget-get widget :children)) :validate))

(defun harness-ui-config--setting-notify (widget _child &optional _event)
  "React to a change inside setting WIDGET: save a pick, note an edit."
  (let ((key (widget-get widget :key))
        (buf (current-buffer)))
    (harness-ui-config--install-field-map)
    ;; An entry added to a list is the setting's too.
    (harness-ui-config--mark-setting widget)
    (if (widget-get widget :discrete)
        ;; Picking the value already saved changes nothing.
        (unless (equal (harness-ui-config--widget-value widget) (widget-get widget :original))
          ;; Kept through a redraw until the save lands.
          (puthash (harness-ui-config--edit-key key) t harness-ui-config--edited)
          (harness-ui-config--set-state key 'saving)
          ;; After the widget is done with the change.
          (harness-run-soon (lambda ()
                              (when (buffer-live-p buf)
                                (with-current-buffer buf (harness-ui-config--save key))))))
      (let ((edited (not (equal (harness-ui-config--widget-value widget) (widget-get widget :original))))
            (ekey (harness-ui-config--edit-key key)))
        (unless (eq (and edited t) (and (gethash ekey harness-ui-config--edited) t))
          (if edited
              (puthash ekey t harness-ui-config--edited)
            (remhash ekey harness-ui-config--edited))
          (remhash ekey harness-ui-config--state)
          (harness-ui-config--show-state key))))))

(defvar harness-ui-config-field-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map widget-field-keymap)
    (define-key map (kbd "RET") #'harness-ui-config-save-setting)
    (define-key map (kbd "C-c C-c") #'harness-ui-config-save-setting)
    (define-key map (kbd "C-c C-k") #'harness-ui-config-revert-setting)
    (define-key map (kbd "C-x C-s") #'harness-ui-config-save-all)
    map)
  "Keymap of the text fields of the settings page.")

(defconst harness-ui-config--field-help
  "RET or C-c C-c saves, C-c C-k reverts, M-TAB completes"
  "Help shown for a text field of the settings page.")

;;;; Types as the page draws them
;;
;; A setting is drawn from its customize type, rewritten first by
;; `harness-ui-config--present'.  Every rewrite keeps the values the
;; type accepts: only the look changes.
;;
;; - A plist whose type names its keys (`:options') is a record: one
;;   line for each key, "[X] Name:  value", the names lined up, with the
;;   key's help (its value type's `:doc') under it.  A key the record
;;   does not have is greyed out with the value it starts from when
;;   ticked (the value type's `:value').  Keys the type does not name
;;   stay at the end, where they can be removed.
;; - A key whose value type is a `const' is a flag: ticking it sets the
;;   key to the constant, and the constant's tag says what that means.
;; - The records of a list fold into one line each: their first key's
;;   value, then the others in brief, and [Edit].
;; - Booleans read on and off, and the text fields of a model setting
;;   complete model ids.

(defun harness-ui-config--type-split (type)
  "Return (NAME PROPS ARGS) of customize TYPE, PROPS a plist."
  (if (symbolp type)
      (list type nil nil)
    (let ((rest (cdr type)) props)
      ;; A keyword that comes last is an argument, as `widget-convert' has it.
      (while (and rest (keywordp (car rest)) (cdr rest))
        (setq props (append props (list (car rest) (cadr rest)))
              rest (cddr rest)))
      (list (car type) props rest))))

(defun harness-ui-config--type-join (name props args)
  "Return the customize type NAME with PROPS and ARGS."
  (if (or props args) (append (list name) props args) name))

(defun harness-ui-config--type-prop (type prop)
  "Return property PROP of customize TYPE."
  (plist-get (nth 1 (harness-ui-config--type-split type)) prop))

(defun harness-ui-config--type-put (type prop value)
  "Return customize TYPE with property PROP set to VALUE."
  (pcase-let ((`(,name ,props ,args) (harness-ui-config--type-split type)))
    (harness-ui-config--type-join name (plist-put (copy-sequence props) prop value) args)))

(defun harness-ui-config--type-is (type &rest names)
  "Non-nil when customize TYPE is one of the widgets NAMES or derives from one."
  (let ((name (if (consp type) (car type) type)) found)
    (while (and name (symbolp name) (not found))
      (if (memq name names)
          (setq found t)
        (setq name (car-safe (get name 'widget-type)))))
    found))

(defun harness-ui-config--match-type (type value)
  "Return TYPE, or the alternative of TYPE that VALUE picks.
For a menu, that is the alternative VALUE fits."
  (if (harness-ui-config--type-is type 'menu-choice 'radio-button-choice)
      (or (cl-loop for a in (nth 2 (harness-ui-config--type-split type))
                   when (harness-ui-config--fits-p a value) return a)
          type)
    type))

(defun harness-ui-config--record-p (type)
  "Non-nil when values of customize TYPE are records: a plist naming its keys.
A cons with a record in it counts too (a name and its record), and a
menu any of whose alternatives is a record."
  (pcase-let ((`(,name ,props ,args) (harness-ui-config--type-split type)))
    (cond ((harness-ui-config--type-is type 'plist) (and (plist-get props :options) t))
          ((eq name 'cons) (and (cl-some #'harness-ui-config--record-p args) t))
          ((harness-ui-config--type-is type 'menu-choice 'radio-button-choice)
           (and (cl-some #'harness-ui-config--record-p args) t)))))

(defun harness-ui-config--form-p (type)
  "Non-nil when customize TYPE holds a record anywhere.
The page draws such a type as a form."
  (or (harness-ui-config--record-p type)
      (pcase-let ((`(,_ ,props ,args) (harness-ui-config--type-split type)))
        (or (cl-some (lambda (o) (and (consp o) (harness-ui-config--form-p (cadr o))))
                     (plist-get props :options))
            (and (not (harness-ui-config--type-is type 'const 'item))
                 (cl-some (lambda (a) (and (or (consp a) (get a 'widget-type)) (harness-ui-config--form-p a)))
                          args))))))

(defun harness-ui-config--untagged-format (type)
  "Return the format of customize TYPE without the tag it starts with.
The value then follows a name the page writes itself."
  (let ((format (or (ignore-errors (widget-get (widget-convert type) :format)) "%v"))
        (case-fold-search nil))
    (if (string-match "\\`%[{[]?%t%[]}]?:[ ]?" format)
        (substring format (match-end 0))
      format)))

(defun harness-ui-config--key-name (key)
  "Return how KEY, a plist key, reads when its type gives it no name."
  (capitalize (replace-regexp-in-string "-" " " (string-remove-prefix ":" (format "%s" key)))))

(defun harness-ui-config--option-tag (option)
  "Return the name of OPTION, a (KEY VALUE-TYPE) of a record, or nil for a flag."
  (unless (harness-ui-config--type-is (cadr option) 'const)
    (or (harness-ui-config--type-prop (cadr option) :tag)
        (harness-ui-config--key-name (car option)))))

(defun harness-ui-config--label-width (options)
  "Return the width of the longest name of OPTIONS, (KEY VALUE-TYPE) each."
  (apply #'max 0 (mapcar (lambda (o) (string-width (or (harness-ui-config--option-tag o) "")))
                         options)))

(defun harness-ui-config--options (props)
  "Return the options of a plist type with PROPS as (KEY VALUE-TYPE) each."
  (mapcar (lambda (o) (if (consp o) o (list o (or (plist-get props :value-type) 'sexp))))
          (plist-get props :options)))

(defun harness-ui-config--present-option (key type width)
  "Return the line of a record for KEY with a value of TYPE, its name WIDTH wide."
  (let* ((doc (harness-ui-config--type-prop type :doc))
         (type (if doc (harness-ui-config--type-put type :doc nil) type))
         (tag (harness-ui-config--option-tag (list key type)))
         (format (harness-ui-config--untagged-format type))
         ;; A value of several lines starts under its name, after the help.
         (block (and tag (or (harness-ui-config--type-is type 'harness-ui-config-plist)
                             (string-prefix-p "\n" format)))))
    `(harness-ui-config-option
      :doc ,doc :block ,block :key ,key
      ,(if tag
           `(const :format ,(concat "%{%t%}:" (make-string (max 0 (- width (string-width tag))) ?\s) " ")
                   :tag ,tag :sample-face harness-settings-label-face ,key)
         `(const :format "" ,key))
      ,(harness-ui-config--type-put type :format (cond ((null tag) "%t\n")
                                                       (block (string-remove-prefix "\n" format))
                                                       (t format))))))

(defun harness-ui-config--present-record (props model &optional width)
  "Return a record type, the plist type with PROPS as the page draws it.
MODEL is as for `harness-ui-config--present'; WIDTH, when given, is the
least width of the names."
  (let* ((options (mapcar (lambda (o) (list (car o) (harness-ui-config--present (cadr o) model)))
                          (harness-ui-config--options props)))
         (width (max (or width 0) (harness-ui-config--label-width options)))
         (rest props) kept)
    (while rest
      (unless (memq (car rest) '(:options :key-type :value-type))
        (setq kept (append kept (list (car rest) (cadr rest)))))
      (setq rest (cddr rest)))
    `(harness-ui-config-plist
      ,@kept
      (checklist :inline t :greedy t
                 ,@(mapcar (lambda (o) (harness-ui-config--present-option (car o) (cadr o) width)) options))
      ;; Keys the type does not name: shown to be removed, never offered.
      (editable-list :inline t :format "%v" :entry-format "%d %v" :offset 6
                     (group :inline t :format "%v"
                            ,(harness-ui-config--present (or (plist-get props :key-type) '(symbol :tag "Other key")) model)
                            ,(harness-ui-config--present (or (plist-get props :value-type) '(sexp :tag "Value")) model))))))

(defun harness-ui-config--present-entry (type model)
  "Return TYPE, an entry of a list, as the page draws it: a record folds.
MODEL is as for `harness-ui-config--present'."
  (let ((presented (harness-ui-config--present type model)))
    (if (harness-ui-config--record-p type)
        ;; The line the record folds into names it: no tag above the form.
        `(harness-ui-config-fold :entry-type ,type ,(harness-ui-config--type-put presented :format "%v"))
      presented)))

(defun harness-ui-config--present-cons (props args model)
  "Return a cons type with PROPS of ARGS, a name and a record, lined up.
The name's value starts where the record's values do.  MODEL is as for
`harness-ui-config--present'."
  (pcase-let* ((`(,car-type ,cdr-type) args)
               (tag (harness-ui-config--type-prop car-type :tag))
               (record-props (nth 1 (harness-ui-config--type-split cdr-type)))
               (width (max (- (string-width (or tag "")) 4)
                           (harness-ui-config--label-width (harness-ui-config--options record-props)))))
    (harness-ui-config--type-join
     'cons props
     (list (if (and tag (equal (harness-ui-config--untagged-format car-type) "%v"))
               (harness-ui-config--type-put
                (harness-ui-config--type-put (harness-ui-config--present car-type model)
                                             :format (concat "%{%t%}:" (make-string (- (+ width 4) (string-width tag)) ?\s)
                                                             " %v"))
                :sample-face 'harness-settings-label-face)
             (harness-ui-config--present car-type model))
           ;; The record's keys follow the name, without a tag of their own.
           (harness-ui-config--type-put (harness-ui-config--present-record record-props model width)
                                        :format "%v")))))

(defun harness-ui-config--present (type &optional model)
  "Return customize TYPE the way the settings page draws it.
MODEL non-nil completes model ids in its text fields.  The type accepts
the same values: only the look changes (see the commentary of this
section)."
  (pcase-let ((`(,name ,props ,args) (harness-ui-config--type-split type)))
    (cond
     ((and (harness-ui-config--type-is type 'plist) (plist-get props :options))
      (harness-ui-config--present-record props model))
     ((and (eq name 'cons) (= (length args) 2) (not (harness-ui-config--record-p (car args)))
           (harness-ui-config--record-p (cadr args)))
      (harness-ui-config--present-cons props args model))
     ((harness-ui-config--type-is type 'editable-list)
      (harness-ui-config--type-join name props (mapcar (lambda (a) (harness-ui-config--present-entry a model))
                                                       args)))
     ((harness-ui-config--type-is type 'plist 'alist)
      (let ((props (copy-sequence props)))
        (dolist (k '(:key-type :value-type))
          (when (plist-get props k)
            (setq props (plist-put props k (harness-ui-config--present (plist-get props k) model)))))
        (harness-ui-config--type-join name props args)))
     ((harness-ui-config--type-is type 'boolean)
      (harness-ui-config--type-join name (append (list :on "on" :off "off") props) args))
     ((and model (harness-ui-config--type-is type 'string) (not (plist-get props :completions)))
      (harness-ui-config--type-put type :completions (harness-ui-config--model-ids)))
     ((harness-ui-config--type-is type 'menu-choice 'radio-button-choice 'group 'checklist)
      (harness-ui-config--type-join name props (mapcar (lambda (a) (harness-ui-config--present a model)) args)))
     (t type))))

;;;;; Records

(define-widget 'harness-ui-config-plist 'list
  "A record on the settings page: a line for each key its type names.
Made by `harness-ui-config--present-record'."
  :value-create #'harness-ui-config--plist-value-create
  :default-get #'ignore)

(defun harness-ui-config--plist-value-create (widget)
  "Insert record WIDGET, without the indentation of an empty last line."
  (widget-group-value-create widget)
  (when (save-restriction (widen) (looking-back "^ +" (line-beginning-position)))
    (delete-region (match-beginning 0) (point))))

(define-widget 'harness-ui-config-option 'group
  "A key of a record on the settings page: its name, value and help."
  :inline t
  :format "%v"
  :value-create #'harness-ui-config--option-value-create
  :match-inline #'harness-ui-config--option-match-inline)

(defun harness-ui-config--option-match-inline (widget values)
  "Claim the key WIDGET names at the head of VALUES, whatever its value.
A key with a value of another type stays the key, drawn with help on
fixing it, rather than falling to the record's other keys."
  (if (equal (car values) (widget-get widget :key))
      (cons (list (car values) (cadr values)) (cddr values))
    nil))

(defun harness-ui-config--insert-help (text column)
  "Insert TEXT, the help of a key, as lines indented to COLUMN."
  (dolist (line (split-string text "\n"))
    (insert (make-string column ?\s) (propertize line 'face 'harness-settings-doc-face) "\n")))

(defun harness-ui-config--widget-type (type)
  "Return customize TYPE as a widget to make a child from.
A type that is only a name is converted; `widget-create-child-value'
needs a converted widget, not a symbol."
  (if (symbolp type) (widget-convert type) type))

(defun harness-ui-config--lisp-widget ()
  "Return the widget a value of another type than its key's is kept in.
A plain one: the value shows as it is, without the sexp editor's
\"Lisp expression\" tag."
  (widget-convert 'sexp :format "%v"))

(defun harness-ui-config--option-value-create (widget)
  "Insert option WIDGET: the key's name and value, and its help.
The help of a value of several lines comes before it, under the name.
A value of another type than the key's keeps its own plain editor, so
it is never lost by editing the rest of the record."
  (let* ((column (+ 2 (save-restriction (widen) (current-column))))
         (doc (widget-get widget :doc))
         (value (widget-get widget :value))
         (given (and (consp value) (eq (car value) (widget-get widget :key))))
         (raw (cadr value))
         (key-type (nth 0 (widget-get widget :args)))
         (value-type (nth 1 (widget-get widget :args)))
         (shown (harness-ui-config--false-nil raw))
         (fits (and given (harness-ui-config--fits-p value-type shown)))
         (key-widget (if given (widget-create-child-value widget key-type (car value))
                       (widget-create-child widget key-type))))
    (when (< (widget-get key-widget :from) (widget-get key-widget :to))
      (put-text-property (widget-get key-widget :from) (widget-get key-widget :to) 'help-echo
                         (format "%s in Lisp" (widget-get widget :key))))
    (when (and doc (widget-get widget :block))
      (insert "\n")
      (harness-ui-config--insert-help doc column)
      (setq doc nil))
    (widget-put widget :children
                (list key-widget
                      (condition-case nil
                          (cond ((and given fits)
                                 (widget-create-child-value widget (harness-ui-config--widget-type value-type) shown))
                                (given (widget-create-child-value widget (harness-ui-config--lisp-widget) raw))
                                (t (widget-create-child widget (harness-ui-config--widget-type value-type))))
                        (error (widget-create-child-value widget (harness-ui-config--lisp-widget) raw)))))
    (when doc
      (unless (bolp) (insert "\n"))
      (harness-ui-config--insert-help doc column))
    (when (and given (not fits))
      (unless (bolp) (insert "\n"))
      (insert (make-string column ?\s)
              (propertize (format "Kept as Lisp: it does not fit %s."
                                  (or (harness-ui-config--type-prop value-type :tag)
                                      (harness-ui-config--key-name (widget-get widget :key))))
                          'face 'warning)
              "\n"))))

;;;;; Folded records

(define-widget 'harness-ui-config-fold 'default
  "A record in a list on the settings page: one line until opened.
Its only argument is the record's type as drawn; `:entry-type' is its
customize type, which sums the record up."
  :format "%v"
  :convert-widget #'widget-types-convert-widget
  :copy #'widget-types-copy
  :value-create #'harness-ui-config--fold-value-create
  :value-delete #'widget-children-value-delete
  :value-get #'harness-ui-config--fold-value-get
  :default-get #'harness-ui-config--fold-default-get
  :validate #'harness-ui-config--fold-validate
  :match #'harness-ui-config--fold-match)

(defun harness-ui-config--setting-of (widget)
  "Return the setting widget WIDGET is part of, or nil."
  (while (and widget (not (eq (widget-type widget) 'harness-ui-config-setting)))
    (setq widget (widget-get widget :parent)))
  widget)

(defun harness-ui-config--setting-key-of (widget)
  "Return the key of the setting WIDGET is part of, or nil."
  (when-let* ((setting (harness-ui-config--setting-of widget)))
    (widget-get setting :key)))

(defun harness-ui-config--mark-setting (setting)
  "Mark the text of SETTING, a setting widget, as its setting's.
Text a widget inserts after the page is drawn (a record opened, an
entry added) lacks the mark the page's commands find settings by."
  (let ((from (widget-get setting :from))
        (to (widget-get setting :to)))
    (when (and (markerp from) (marker-buffer from) (< from to))
      (with-silent-modifications
        (put-text-property from to 'harness-ui-config-key (widget-get setting :key))))))

(defun harness-ui-config--nested-fold-p (widget)
  "Non-nil when WIDGET is a record within another record."
  (let ((parent (widget-get widget :parent)) found)
    (while (and parent (not found))
      (setq found (eq (widget-type parent) 'harness-ui-config-fold)
            parent (widget-get parent :parent)))
    found))

(defun harness-ui-config--fold-open-p (widget)
  "Non-nil when record WIDGET is drawn open.
A record drawn with the page is open when it was before; one added
since, with [INS], starts open, and one within another record folded."
  (pcase (widget-get widget :open)
    ('yes t)
    ('no nil)
    (_ (or (and (member (cons (harness-ui-config--setting-key-of widget) (widget-get widget :value))
                         harness-ui-config--open-folds)
                t)
           (and (not harness-ui-config--drawing)
                (not (harness-ui-config--nested-fold-p widget)))))))

(defun harness-ui-config--summary-width ()
  "Return the columns the summary of a record may take on its line, from point."
  (let ((window (get-buffer-window (current-buffer) t)))
    (max 40 (- (if window (window-body-width window) 100)
               (save-restriction (widen) (current-column))
               10))))

(defun harness-ui-config--fold-value-create (widget)
  "Insert record WIDGET: the line summing it up, then its form when open."
  (let* ((value (widget-get widget :value))
         (open (harness-ui-config--fold-open-p widget)))
    (widget-put widget :open (if open 'yes 'no))
    (cl-pushnew widget harness-ui-config--folds :test #'eq)
    (insert (harness-ui-config--summary (widget-get widget :entry-type) value
                                        (harness-ui-config--summary-width))
            "  ")
    (widget-put widget :buttons
                (list (widget-create-child-and-convert
                       widget 'push-button
                       :help-echo (if open "Fold this entry into its line" "Show every key of this entry")
                       :notify #'harness-ui-config--fold-toggle
                       (if open "Hide" "Edit"))))
    (insert "\n")
    (when open
      (widget-put widget :children
                  (list (widget-create-child-value widget (car (widget-get widget :args)) value))))))

(defun harness-ui-config--fold-toggle (button &rest _)
  "Open or fold the record of BUTTON, once the widget library is done with it."
  (let ((fold (widget-get button :parent))
        (buffer (current-buffer)))
    (harness-run-soon
     (lambda ()
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when (markerp (widget-get fold :from))
             (let ((bad (widget-apply fold :validate)))
               (if bad
                   (message "%s" (or (widget-get bad :error) "This entry holds an invalid value"))
                 (widget-put fold :open (if (eq (widget-get fold :open) 'yes) 'no 'yes))
                 (widget-value-set fold (widget-value fold))
                 (widget-setup)
                 (harness-ui-config--install-field-map)
                 (when-let* ((setting (harness-ui-config--setting-of fold)))
                   (harness-ui-config--mark-setting setting)))))))))))

(defun harness-ui-config--fold-value-get (widget)
  "Return the value of record WIDGET: its form's when open."
  (if-let* ((child (car (widget-get widget :children))))
      (widget-value child)
    (widget-get widget :value)))

(defun harness-ui-config--fold-default-get (widget)
  "Return the value a new record of WIDGET's type starts with."
  (widget-default-get (car (widget-get widget :args))))

(defun harness-ui-config--fold-validate (widget)
  "Return the widget of record WIDGET that holds no valid value, or nil."
  (if-let* ((child (car (widget-get widget :children))))
      (widget-apply child :validate)
    (unless (widget-apply (car (widget-get widget :args)) :match (widget-get widget :value))
      (widget-put widget :error "This entry holds an invalid value")
      widget)))

(defun harness-ui-config--fold-match (widget value)
  "Non-nil when VALUE fits the type of record WIDGET."
  (widget-apply (car (widget-get widget :args)) :match value))

(defun harness-ui-config--note-open-folds ()
  "Remember which records are open, to draw them open again.
Without records on the page (a second snapshot before one redraw, or
the other scope's page), what was noted before stays."
  (when harness-ui-config--folds
    (setq harness-ui-config--open-folds
          (cl-loop for fold in harness-ui-config--folds
                   when (and (eq (widget-get fold :open) 'yes)
                             (markerp (widget-get fold :from))
                             (marker-buffer (widget-get fold :from)))
                   collect (cons (harness-ui-config--setting-key-of fold)
                                 (condition-case nil (widget-value fold) (error nil))))
          harness-ui-config--folds nil)))

;;;;; Summaries

(defun harness-ui-config--short-number (n)
  "Return number N written short: thousands grouped, as 128,000."
  (if (and (integerp n) (>= (abs n) 10000))
      (let ((digits (number-to-string (abs n))) parts)
        (while (> (length digits) 3)
          (push (substring digits -3) parts)
          (setq digits (substring digits 0 -3)))
        (concat (if (< n 0) "-" "") (string-join (cons digits parts) ",")))
    (format "%s" n)))

(defun harness-ui-config--short (type value)
  "Return VALUE of customize TYPE in a few words."
  (pcase-let ((`(,_ ,props ,args) (harness-ui-config--type-split type)))
    (cond
     ((harness-ui-config--type-is type 'const 'item)
      (or (plist-get props :tag) (format "%s" value)))
     ((harness-ui-config--type-is type 'menu-choice 'radio-button-choice)
      (or (cl-loop for a in args
                   when (harness-ui-config--fits-p a value)
                   return (harness-ui-config--short a value))
          (format "%S" value)))
     ((harness-ui-config--type-is type 'boolean) (if value "on" "off"))
     ((harness-ui-config--record-p type) (harness-ui-config--summary type value nil t))
     ((and (harness-ui-config--type-is type 'editable-list) (harness-ui-config--record-p (car args))
           (listp value))
      (mapconcat (lambda (v) (harness-ui-config--record-name (car args) v)) value ", "))
     ((numberp value) (harness-ui-config--short-number value))
     ((stringp value) value)
     ((and value (listp value) (cl-every #'atom value))
      (mapconcat (lambda (v) (format "%s" v)) value ", "))
     ((symbolp value) (symbol-name value))
     (t (let ((print-length 4) (print-level 2)) (prin1-to-string value))))))

(defun harness-ui-config--false-nil (value)
  "Return VALUE as Lisp: the JSON false `:false' is nil here.
The harness reads `:false' and nil alike, so a setting that carries
one must still be savable."
  (if (eq value :false) nil value))

(defun harness-ui-config--record-name (type value)
  "Return the name of VALUE, a record of customize TYPE.
That is the value of its first key, or the car of a cons."
  (pcase-let ((`(,name ,props ,args) (harness-ui-config--type-split
                                      (harness-ui-config--match-type type value))))
    (if (eq name 'cons)
        (harness-ui-config--short (car args) (car-safe value))
      (let ((first (car (harness-ui-config--options props))))
        (if (and first (listp value) (plist-member value (car first)))
            (harness-ui-config--short (cadr first) (plist-get value (car first)))
          "?")))))

(defun harness-ui-config--summary-parts (type value named nested)
  "Return the parts that sum up VALUE, a record of customize TYPE.
NAMED non-nil: the record's first key is its name, which comes first,
bold.  Then each key it has: text as it is (unless NESTED, within
another record), flags by their tag, the rest after the key's name."
  (let ((props (nth 1 (harness-ui-config--type-split type))))
    (cl-loop for (key vtype) in (harness-ui-config--options props)
             for first = named then nil
             when (and (listp value) (plist-member value key))
             collect (let* ((v (plist-get value key))
                            (short (harness-ui-config--short vtype v))
                            (tag (harness-ui-config--option-tag (list key vtype))))
                       (cond (first (propertize short 'face 'harness-settings-label-face))
                             ((null tag) short)
                             ;; Text, and a value picked from a menu or
                             ;; named by a tag, read well as they are.
                             ((and (not nested)
                                   (or (stringp v)
                                       (harness-ui-config--type-is vtype 'const 'menu-choice
                                                                   'radio-button-choice)))
                              short)
                             (t (concat tag " " short)))))))

(defun harness-ui-config--summary (type value &optional width nested)
  "Return the line that sums up VALUE, a record of customize TYPE.
The record's name (its first key, or the car of a cons) comes first,
then what `harness-ui-config--summary-parts' says of each key.  WIDTH,
when given, is the most columns it may take.  NESTED non-nil sums up a
record within another: no name, and commas between the keys."
  (pcase-let* ((type (harness-ui-config--match-type type value))
               (`(,name ,_ ,args) (harness-ui-config--type-split type))
               (parts (if (eq name 'cons)
                          (cons (propertize (harness-ui-config--short (car args) (car-safe value))
                                            'face 'harness-settings-label-face)
                                (harness-ui-config--summary-parts (cadr args) (cdr-safe value) nil nil))
                        (harness-ui-config--summary-parts type value (not nested) nested)))
               (text (replace-regexp-in-string
                      "\n" " " (string-join (cl-remove-if #'string-empty-p parts)
                                            (if nested ", " " · ")))))
    (if width (truncate-string-to-width text width nil nil "…") text)))

(defun harness-ui-config--install-field-map ()
  "Give every text field of the page `harness-ui-config-field-map'.
That is each field's overlay and the one on the newline ending it
\(`real-field'), which point is on at the end of the text; both carry
the keymap of the field's type, which customize (loaded here) makes
`custom-field-keymap'."
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (and (overlay-get ov 'local-map)
               (or (overlay-get ov 'field) (overlay-get ov 'real-field)))
      (overlay-put ov 'local-map harness-ui-config-field-map)
      ;; The field's own help says RET moves on; here it saves.
      (let ((field (overlay-get ov 'field)))
        (when (and field (not (eq field 'boundary)))
          (widget-put field :help-echo harness-ui-config--field-help)
          (overlay-put ov 'help-echo harness-ui-config--field-help))))))

;;;; Drawing

(defun harness-ui-config--button (label help fn &optional redraws)
  "Insert a push button LABEL with tooltip HELP calling FN.
REDRAWS non-nil says FN redraws the page at once: it then runs after the
widget library is done with the button, which would be gone."
  (let ((buf (current-buffer)))
    (widget-create 'push-button
                   :help-echo help
                   :notify (if redraws
                               (lambda (&rest _)
                                 (harness-run-soon (lambda ()
                                                     (when (buffer-live-p buf)
                                                       (with-current-buffer buf (funcall fn))))))
                             (lambda (&rest _) (funcall fn)))
                   label)))

(defun harness-ui-config--insert-doc (setting)
  "Insert the documentation of SETTING, indented.
A setting drawn as a form, whose keys have help of their own, shows the
first line of it and [More] for the rest."
  (let* ((key (plist-get setting :key))
         (doc (string-trim (or (ignore-errors (substitute-command-keys (plist-get setting :doc)))
                               (plist-get setting :doc) "")))
         (lines (split-string doc "\n"))
         (foldable (and (cdr lines) (harness-ui-config--true (plist-get setting :editable))
                        (harness-ui-config--form-p (harness-ui-config--type setting))))
         (shown (member key harness-ui-config--docs-shown)))
    (unless (string-empty-p doc)
      (insert "    " (propertize (car lines) 'face 'harness-settings-doc-face))
      (when foldable
        (insert "  ")
        (harness-ui-config--button (if shown "Less" "More")
                                   (if shown "Show the first line of the documentation only"
                                     "Show the whole documentation")
                                   (lambda ()
                                     (setq harness-ui-config--docs-shown
                                           (if (member key harness-ui-config--docs-shown)
                                               (delete key harness-ui-config--docs-shown)
                                             (cons key harness-ui-config--docs-shown)))
                                     (harness-ui-config--render))
                                   t))
      (insert "\n")
      (when (or shown (not foldable))
        (dolist (line (cdr lines))
          (insert "    " (propertize line 'face 'harness-settings-doc-face) "\n"))))))

(defun harness-ui-config--dir-label (dir)
  "Return DIR relative to the page's project root when inside it."
  (let ((root (plist-get harness-ui-config--data :root)))
    (if (and root (string-prefix-p root dir) (not (equal root dir)))
        (file-relative-name dir root)
      (abbreviate-file-name dir))))

(defun harness-ui-config--status (setting)
  "Return (TEXT . BUTTONS) saying where SETTING's value comes from.
BUTTONS are (LABEL HELP FUNCTION)."
  (let* ((key (plist-get setting :key))
         (layered (harness-ui-config--true (plist-get setting :layered)))
         (global (harness-ui-config--read (plist-get setting :global)))
         (standard (harness-ui-config--read (plist-get setting :standard)))
         (customized (not (equal (plist-get setting :global) (plist-get setting :standard))))
         (project (plist-get setting :project))
         (directory (plist-get setting :directory))
         (show (lambda (v) (harness-ui-config--show v setting)))
         (dir-note
          (when directory
            (propertize (format "%s sets %s for sessions there"
                                (harness-ui-config--dir-label (plist-get harness-ui-config--data :cwd))
                                (funcall show (harness-ui-config--read directory)))
                        'face 'harness-settings-directory-face)))
         parts buttons)
    (cond
     ((harness-ui-config--true (plist-get setting :secret))
      (push (propertize "a secret: saved globally, never shown here" 'face 'harness-settings-doc-face) parts))
     ((eq harness-ui-config--scope 'project)
      (if project
          (progn
            (push (propertize (format "set for %s" (harness-ui-config--place)) 'face 'harness-settings-project-face)
                  parts)
            (push (propertize (format "global is %s" (funcall show global)) 'face 'harness-settings-doc-face)
                  parts)
            (push (list "Remove override"
                        "Delete this setting from the .dir-locals.el, so the global value applies (d)"
                        (lambda () (harness-ui-config--unset key)))
                  buttons))
        (push (propertize "uses the global value" 'face 'harness-settings-doc-face) parts)))
     (t
      (if customized
          (progn
            (push (propertize "customized" 'face 'harness-settings-global-face) parts)
            (push (propertize (format "default is %s" (funcall show standard)) 'face 'harness-settings-doc-face)
                  parts)
            (push (list "Reset to default" "Set the global value back to the default (d)"
                        (lambda () (harness-ui-config--unset key)))
                  buttons)))
      (when (and layered project)
        (push (propertize (format "%s uses %s" (harness-ui-config--place)
                                  (funcall show (harness-ui-config--read project)))
                          'face 'harness-settings-project-face)
              parts))))
    (when dir-note (push dir-note parts))
    (cons (string-join (nreverse parts) (propertize " \u00b7 " 'face 'harness-settings-doc-face))
          (nreverse buttons))))

(defun harness-ui-config--insert-status (setting)
  "Insert the status line of SETTING when it has something to say.
Then the blank line that ends the setting, where its edit state shows."
  (let* ((key (plist-get setting :key))
         (status (harness-ui-config--status setting))
         (ov nil))
    (unless (and (string-empty-p (car status)) (null (cdr status)))
      (insert "    " (car status))
      (dolist (b (cdr status))
        (insert "  ")
        (apply #'harness-ui-config--button b))
      (insert "\n"))
    (setq ov (make-overlay (point) (point)))
    (overlay-put ov 'harness-ui-config t)
    (puthash key ov harness-ui-config--overlays)
    (insert "\n")
    (harness-ui-config--show-state key)))

(defun harness-ui-config--insert-label (label)
  "Insert LABEL the way a widget tag shows."
  (insert (propertize label 'face 'harness-settings-label-face) ": "))

(defun harness-ui-config--insert-secret (setting label)
  "Insert secret SETTING named LABEL: whether it is set, and buttons for it."
  (let ((key (plist-get setting :key))
        (set (harness-ui-config--true (plist-get setting :has-value))))
    (harness-ui-config--insert-label label)
    (insert (if set (propertize "\u25cf\u25cf\u25cf\u25cf\u25cf\u25cf\u25cf\u25cf" 'face 'default 'help-echo "Set; the page never shows a secret")
              (propertize "not set" 'face 'harness-settings-doc-face))
            "  ")
    (harness-ui-config--button (if set "Change\u2026" "Set\u2026") "Type a new value; it is never shown"
                               (lambda () (harness-ui-config--read-secret key label)))
    (when set
      (insert " ")
      (harness-ui-config--button "Clear" "Remove the value"
                                 (lambda () (harness-ui-config--unset key))))
    (insert "\n")))

(defun harness-ui-config--insert-text (setting label value)
  "Insert SETTING named LABEL whose VALUE is a long text, and a button to edit it."
  (let* ((key (plist-get setting :key))
         (lines (length (split-string value "\n")))
         (first (harness-truncate-end (harness-first-line value) 56)))
    (harness-ui-config--insert-label label)
    (insert (propertize (format "\u201c%s\u201d" first) 'face 'default)
            (propertize (if (> lines 1) (format " %d lines" lines) "") 'face 'harness-settings-doc-face)
            "  ")
    (harness-ui-config--button "Edit\u2026" "Edit the text in its own buffer; C-c C-c saves it"
                               (lambda () (harness-ui-config--edit-text key label)))
    (insert "\n")))

(defun harness-ui-config--insert-widget (setting label type value original)
  "Insert the setting widget of SETTING with LABEL editing VALUE of TYPE.
ORIGINAL is the value saved in the page's scope."
  (let* ((key (plist-get setting :key))
         ;; The saved value picks the editor, so an edit never changes it.
         (fits (harness-ui-config--fits-p type original))
         ;; M-TAB completes model ids from the catalogue in a model setting.
         (edit-type (if fits (harness-ui-config--present type (string-suffix-p "-model" key)) 'sexp))
         (widget (let ((harness-ui-config--drawing t))
                   (widget-create 'harness-ui-config-setting
                                  :key key :tag label :edit-type edit-type
                                  :value value :original original
                                  :discrete (and fits (harness-ui-config--discrete-p type))))))
    (unless (bolp) (insert "\n"))
    (push (cons key widget) harness-ui-config--widgets)
    ;; Only the harness can tell: a type may name functions defined there alone.
    (when (member (if (and (eq harness-ui-config--scope 'project) (plist-get setting :project))
                      "project" "global")
                  (plist-get setting :invalid))
      (insert "    " (propertize "This value does not fit the setting's type, so it is edited as Lisp."
                                 'face 'warning)
              "\n"))))

(defun harness-ui-config--insert-setting (setting)
  "Insert SETTING, a plist of `config/describe', for the page's scope."
  (let* ((key (plist-get setting :key))
         (start (point))
         (label (harness-ui-config--label setting)))
    (insert " ")
    (cond
     ((harness-ui-config--true (plist-get setting :secret))
      (harness-ui-config--insert-secret setting label))
     ((not (harness-ui-config--true (plist-get setting :editable)))
      (harness-ui-config--insert-label label)
      (insert (harness-truncate-end (or (plist-get setting :value) "") 60)
              (propertize "  (set in Lisp; change it in your init file)" 'face 'harness-settings-doc-face)
              "\n"))
     (t
      (let* ((type (harness-ui-config--type setting))
             (original (harness-ui-config--scope-value setting harness-ui-config--scope))
             (box (gethash (harness-ui-config--edit-key key) harness-ui-config--edited))
             (value (if (consp box) (car box) original)))
        ;; The edit goes back into the widget drawn now.
        (when (consp box) (puthash (harness-ui-config--edit-key key) t harness-ui-config--edited))
        (if (and (stringp original) (harness-ui-config--fits-p type original)
                 (or (string-search "\n" original) (> (length original) 100)))
            (harness-ui-config--insert-text setting label value)
          (harness-ui-config--insert-widget setting label type value original)))))
    (harness-ui-config--insert-doc setting)
    (harness-ui-config--insert-status setting)
    (put-text-property start (point) 'harness-ui-config-key key)))

(defun harness-ui-config--insert-heading (title &optional doc)
  "Insert section TITLE and its DOC."
  (insert " " (propertize title 'face 'harness-settings-heading-face) "\n")
  (when (and doc (not (string-empty-p doc)))
    (insert " " (propertize doc 'face 'harness-settings-doc-face) "\n"))
  (insert "\n"))

(defun harness-ui-config--scope-help ()
  "Return what the scope shown edits and where it is saved."
  (let ((files (plist-get harness-ui-config--data :files)))
    (if (eq harness-ui-config--scope 'global)
        (format "Global values apply to every project that does not override them.  Saved in %s."
                (if custom-file (abbreviate-file-name custom-file) "your init file, through customize"))
      (format "Values set here override the global ones for sessions in %s.  Saved in its .dir-locals.el%s."
              (if (harness-ui-config--in-project-p) (harness-ui-config--project-name) "this directory")
              (if (harness-ui-config--true (plist-get files :project-exists)) "" ", created on the first save")))))

(defun harness-ui-config--insert-top ()
  "Insert the title, the project and the scope toggle."
  (let ((buf (current-buffer)))
    (insert "\n " (propertize "Settings" 'face 'harness-settings-title-face)
            (propertize (concat "  " (harness-ui-config--project-name)) 'face 'harness-settings-heading-face)
            "\n " (propertize (abbreviate-file-name (or (plist-get harness-ui-config--data :root)
                                                        harness-ui-config--root ""))
                              'face 'harness-settings-doc-face)
            "\n\n " (propertize "Scope" 'face 'harness-settings-label-face) "   ")
    (widget-create 'radio-button-choice
                   :value harness-ui-config--scope
                   :format "%v"
                   :entry-format "%b %v"
                   :help-echo "Which values the page edits (s)"
                   :notify (lambda (w &rest _)
                             (let ((scope (widget-value w)))
                               (harness-run-soon (lambda ()
                                                   (when (buffer-live-p buf)
                                                     (with-current-buffer buf (harness-ui-config-set-scope scope)))))))
                   `(item :tag "Global" :format "%t     " :value global)
                   `(item :tag ,(harness-ui-config--scope-label 'project) :format "%t" :value project))
    (insert "\n " (propertize (harness-ui-config--scope-help) 'face 'harness-settings-doc-face) "\n\n")))

(defconst harness-ui-config--fallback-section
  '(:name "sessions" :title "Session defaults"
    :doc "New sessions start with these.  Each project can override them in its .dir-locals.el.")
  "The one section of a harness that names none: its layered settings.")

(defun harness-ui-config--sections ()
  "Return the sections of the page, plists of :name :title :doc, in order."
  (or (plist-get harness-ui-config--data :sections)
      (list harness-ui-config--fallback-section)))

(defun harness-ui-config--section-of (setting)
  "Return the name of the section SETTING is shown in, or nil when advanced."
  (let ((section (plist-get setting :section)))
    (cond ((and (stringp section) (not (string-empty-p section))) section)
          ;; A harness from before sections listed its layered settings first.
          ((and (null (plist-get harness-ui-config--data :sections))
                (harness-ui-config--true (plist-get setting :layered)))
           (plist-get harness-ui-config--fallback-section :name)))))

(defun harness-ui-config--advanced-p (setting)
  "Non-nil when SETTING is an advanced one, folded away at first."
  (null (harness-ui-config--section-of setting)))

(defun harness-ui-config--customized-p (setting)
  "Non-nil when the global value of SETTING is not its default."
  (if (harness-ui-config--true (plist-get setting :secret))
      (harness-ui-config--true (plist-get setting :has-value))
    (not (equal (plist-get setting :global) (plist-get setting :standard)))))

(defun harness-ui-config--insert-sections (settings)
  "Insert the sections of SETTINGS that the page's scope shows."
  (let ((project (eq harness-ui-config--scope 'project)))
    (dolist (section (harness-ui-config--sections))
      (let ((members (cl-remove-if-not
                      (lambda (s) (and (equal (harness-ui-config--section-of s) (plist-get section :name))
                                       (or (not project) (harness-ui-config--true (plist-get s :layered)))))
                      settings)))
        (when members
          (harness-ui-config--insert-heading (plist-get section :title) (plist-get section :doc))
          (mapc #'harness-ui-config--insert-setting members))))))

(defun harness-ui-config--insert-by-module (settings)
  "Insert SETTINGS under the title of the module of each."
  (let ((modules (delete-dups (mapcar (lambda (s) (plist-get s :module)) settings))))
    (setq modules (sort modules (lambda (a b)
                                  (cond ((equal a "core") nil)
                                        ((equal b "core") t)
                                        (t (string< (harness-ui-config--module-title a)
                                                    (harness-ui-config--module-title b)))))))
    (dolist (module modules)
      (harness-ui-config--insert-heading
       (harness-ui-config--module-title module)
       (plist-get (cl-find module (plist-get harness-ui-config--data :modules)
                           :key (lambda (m) (plist-get m :name)) :test #'equal)
                  :doc))
      (dolist (s settings)
        (when (equal module (plist-get s :module))
          (harness-ui-config--insert-setting s))))))

(defun harness-ui-config--insert-advanced (advanced)
  "Insert the line about the ADVANCED settings, and them when they are shown."
  (when advanced
    (let ((changed (cl-count-if #'harness-ui-config--customized-p advanced)))
      (insert " " (propertize "Advanced" 'face 'harness-settings-heading-face) "  ")
      (harness-ui-config--button (if harness-ui-config--show-advanced
                                     "Hide them"
                                   (format "Show %d more" (length advanced)))
                                 "Show or hide the settings few people need (a)"
                                 #'harness-ui-config-toggle-advanced t)
      (insert "\n "
              (propertize "Settings few people need: programs, provider details, how tasks are kept."
                          'face 'harness-settings-doc-face)
              (if (> changed 0)
                  (concat "  " (propertize (format "%d changed here." changed)
                                           'face 'harness-settings-global-face))
                "")
              "\n\n")
      (when harness-ui-config--show-advanced
        (harness-ui-config--insert-by-module advanced)))))

(defun harness-ui-config--insert-global-only (others)
  "Insert the line about OTHERS, the settings with a global value only."
  (when others
    (harness-ui-config--insert-heading "Other settings")
    (insert " " (propertize (format "%d more settings have a global value only, the same in every project."
                                    (length others))
                            'face 'harness-settings-doc-face)
            "\n ")
    (harness-ui-config--button "Edit global settings" "Show the Global scope (s)"
                               (lambda () (harness-ui-config-set-scope 'global)) t)
    (insert "\n")))

(defun harness-ui-config--insert-interface ()
  "Insert where the options of the interface are set."
  (harness-ui-config--insert-heading
   "Interface"
   "Where windows open, the prefix key, labels and faces: options of this Emacs, set with Customize.")
  (insert " ")
  (harness-ui-config--button "Customize the interface" "M-x customize-group harness-ui (C)"
                             #'harness-ui-config-customize-interface)
  (insert "\n"))

(defun harness-ui-config--insert-settings ()
  "Insert the sections of settings for the page's scope, then the others."
  (let ((settings (plist-get harness-ui-config--data :settings)))
    (harness-ui-config--insert-sections settings)
    (if (eq harness-ui-config--scope 'project)
        (harness-ui-config--insert-global-only
         (cl-remove-if (lambda (s) (harness-ui-config--true (plist-get s :layered))) settings))
      (harness-ui-config--insert-advanced (cl-remove-if-not #'harness-ui-config--advanced-p settings))
      (harness-ui-config--insert-interface))))

(defun harness-ui-config--position ()
  "Return where point is as (KEY . OFFSET), or the plain position."
  (let ((key (get-text-property (point) 'harness-ui-config-key)))
    (if key
        (cons key (- (point) (or (harness-ui-config--setting-start key) (point))))
      (point))))

(defun harness-ui-config--setting-start (key)
  "Return where the setting KEY starts on the page, or nil."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((match (text-property-search-forward 'harness-ui-config-key key t)))
      (prop-match-beginning match))))

(defun harness-ui-config--restore (position)
  "Move point back to POSITION from `harness-ui-config--position'."
  (goto-char (point-min))
  (if (consp position)
      (when-let* ((start (harness-ui-config--setting-start (car position))))
        (goto-char (min (point-max) (+ start (cdr position)))))
    (goto-char (min (point-max) position))))

(defun harness-ui-config--clear ()
  "Erase the page and forget its widgets."
  (let ((inhibit-read-only t)
        (inhibit-modification-hooks t))
    (erase-buffer))
  (remove-overlays)
  (setq widget-field-new nil widget-field-list nil widget-field-last nil widget-field-was nil
        harness-ui-config--widgets nil harness-ui-config--folds nil)
  (clrhash harness-ui-config--overlays))

(defun harness-ui-config--render ()
  "Draw the page from `harness-ui-config--data', keeping edits and point."
  (let ((position (harness-ui-config--position))
        (starts (mapcar (lambda (w) (cons w (window-start w)))
                        (get-buffer-window-list (current-buffer) nil t))))
    (harness-ui-config--snapshot)
    (harness-ui-config--clear)
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t))
      (harness-ui-config--insert-top)
      (cond
       ((and (null harness-ui-config--data) harness-ui-config--error)
        (insert " " (propertize (format "Could not load the settings: %s" harness-ui-config--error) 'face 'error)
                "\n\n ")
        (harness-ui-config--button "Retry" "Ask the harness again (g)" #'harness-ui-config-refresh)
        (insert "\n"))
       ((null harness-ui-config--data)
        (insert " " (propertize "Loading settings\u2026" 'face 'harness-settings-doc-face) "\n"))
       (t (harness-ui-config--insert-settings))))
    (widget-setup)
    (harness-ui-config--install-field-map)
    (harness-ui-config--restore position)
    (dolist (cell starts)
      (when (window-live-p (car cell))
        (set-window-start (car cell) (min (cdr cell) (point-max)) t)))))

;;;; Header line

(defun harness-ui-config--segment (label command help &optional face)
  "Return a header-line segment LABEL running COMMAND with tooltip HELP.
FACE defaults to `harness-label-face'."
  (propertize (format " %s " label)
              'face (or face 'harness-label-face)
              'mouse-face 'mode-line-highlight
              'help-echo help
              'local-map (harness-ui-mouse-keymap command)))

(defun harness-ui-config--scope-segment (scope)
  "Return the header-line segment selecting SCOPE."
  (let ((edits (harness-ui-config--edit-count scope)))
    (harness-ui-config--segment
     (concat (harness-ui-config--scope-label scope) (if (> edits 0) "\u2022" ""))
     (lambda () (interactive) (harness-ui-config-set-scope scope))
     (format "Edit the %s values%s" (downcase (harness-ui-config--scope-label scope))
             (if (> edits 0) (format " (%d %s not saved)" edits (if (= edits 1) "edit" "edits")) ""))
     (if (eq scope harness-ui-config--scope) 'harness-settings-selected-face 'harness-label-face))))

(defun harness-ui-config--header ()
  "Return the header line of the settings page."
  (let ((edits (harness-ui-config--edit-count)))
    (list (propertize " Settings " 'face 'harness-settings-heading-face)
          (harness-ui-config--scope-segment 'global)
          (harness-ui-config--scope-segment 'project)
          "  "
          (propertize (abbreviate-file-name (or (plist-get harness-ui-config--data :root)
                                                harness-ui-config--root ""))
                      'face 'harness-settings-doc-face)
          "  "
          (cond (harness-ui-config--loading (propertize "loading\u2026 " 'face 'harness-settings-doc-face))
                (harness-ui-config--error (propertize (format "error: %s " harness-ui-config--error) 'face 'error))
                (t ""))
          (if (> edits 0)
              (concat (propertize (format "%d edited " edits) 'face 'harness-settings-edited-face)
                      (harness-ui-config--segment "save" #'harness-ui-config-save-all "Save every edit (C-x C-s)")
                      (harness-ui-config--segment "revert" #'harness-ui-config-revert-all "Drop every edit"))
            "")
          (harness-ui-config--segment "g" #'harness-ui-config-refresh "Reload the settings (g)")
          (harness-ui-config--segment "q" #'quit-window "Quit (q)"))))

;;;; Loading

(defun harness-ui-config--load (buffer)
  "Fetch the settings of BUFFER's directory and draw them."
  (with-current-buffer buffer
    (let ((gen (cl-incf harness-ui-config--generation)))
      (setq harness-ui-config--loading t)
      (force-mode-line-update)
      (harness-ui-call
       "_harness/config/describe" (list :cwd harness-ui-config--cwd)
       (lambda (data)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (= gen harness-ui-config--generation)
               (setq harness-ui-config--data data
                     harness-ui-config--root (plist-get data :root)
                     harness-ui-config--loading nil
                     harness-ui-config--error nil)
               (harness-ui-config--render)))))
       (lambda (e)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (= gen harness-ui-config--generation)
               (setq harness-ui-config--loading nil
                     harness-ui-config--error (harness-error-message e))
               (harness-ui-config--render)))))))))

(defun harness-ui-config--reload-soon (buffer)
  "Reload BUFFER shortly, once for a burst of changes."
  (harness-debounce (list 'harness-ui-config buffer) 0.15
                    (lambda () (when (buffer-live-p buffer) (harness-ui-config--load buffer)))))

;;;; Saving

(defun harness-ui-config--setting (key)
  "Return the `config/describe' plist of KEY."
  (cl-find key (plist-get harness-ui-config--data :settings)
           :key (lambda (s) (plist-get s :key)) :test #'equal))

(defun harness-ui-config--save-value (key value)
  "Save VALUE for KEY in the page's scope; return the request's promise."
  (let ((scope harness-ui-config--scope)
        (buf (current-buffer))
        (label (harness-ui-config--label (harness-ui-config--setting key))))
    (harness-ui-config--set-state key 'saving scope)
    (harness-ui-call
     "_harness/config/set"
     (list :key key :value (harness-ui-config--print value) :printed t
           :scope (symbol-name scope) :cwd harness-ui-config--cwd)
     (lambda (_)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (let* ((widget (harness-ui-config--widget key))
                  (current (and widget (ignore-errors (harness-ui-config--widget-value widget)))))
             ;; The widget holds what was saved, so a change that
             ;; arrives before the redraw is not a new edit; one made
             ;; while the save was on its way still is.
             (when (and widget (equal current value))
               (widget-put widget :original value)
               (remhash (harness-ui-config--edit-key key scope) harness-ui-config--edited))
             (unless widget
               (remhash (harness-ui-config--edit-key key scope) harness-ui-config--edited)))
           (harness-ui-config--set-state key nil scope)
           (harness-ui-config--reload-soon buf))))
     (lambda (e)
       (let ((msg (harness-error-message e)))
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (puthash (harness-ui-config--edit-key key scope) t harness-ui-config--edited)
             (harness-ui-config--set-state key (cons 'error msg) scope)))
         (message "Could not save %s: %s" label msg))))))

(defun harness-ui-config--save (key)
  "Save the value the widget of KEY holds in the page's scope."
  (let ((widget (or (harness-ui-config--widget key) (user-error "%s is not edited on this page" key))))
    (when-let* ((bad (widget-apply widget :validate)))
      (harness-ui-config--set-state key (cons 'error (or (widget-get bad :error) "invalid value")))
      (user-error "%s: %s" (widget-get widget :tag) (or (widget-get bad :error) "invalid value")))
    (harness-ui-config--save-value key (widget-value widget))))

(defun harness-ui-config--unset (key)
  "Remove KEY's value in the page's scope: the override, or back to the default."
  (let ((scope harness-ui-config--scope)
        (buf (current-buffer))
        (label (harness-ui-config--label (harness-ui-config--setting key))))
    (remhash (harness-ui-config--edit-key key scope) harness-ui-config--edited)
    (harness-ui-config--set-state key 'saving scope)
    (harness-ui-call
     "_harness/config/unset"
     (list :key key :scope (symbol-name scope) :cwd harness-ui-config--cwd)
     (lambda (_)
       (if (eq scope 'project)
           (message "%s: %s uses the global value again" label
                    (if (buffer-live-p buf) (with-current-buffer buf (harness-ui-config--place)) "the project"))
         (message "%s: back to the default" label))
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (harness-ui-config--set-state key nil scope)
           (harness-ui-config--reload-soon buf))))
     (lambda (e)
       (let ((msg (harness-error-message e)))
         (when (buffer-live-p buf)
           (with-current-buffer buf (harness-ui-config--set-state key (cons 'error msg) scope)))
         (message "Could not change %s: %s" label msg))))))

(defun harness-ui-config--read-secret (key label)
  "Read a new value for secret KEY named LABEL and save it globally."
  (let ((value (read-passwd (format "%s (empty to clear): " label))))
    (unwind-protect
        (if (string-empty-p value)
            (harness-ui-config--unset key)
          (harness-ui-config--save-value key (copy-sequence value)))
      (clear-string value))))

(defun harness-ui-config--edit-text (key label)
  "Edit the long text of KEY named LABEL in its own buffer; saving it saves KEY."
  (require 'string-edit)
  (let* ((buf (current-buffer))
         (setting (harness-ui-config--setting key))
         (box (gethash (harness-ui-config--edit-key key) harness-ui-config--edited))
         (value (if (consp box) (car box)
                  (harness-ui-config--scope-value setting harness-ui-config--scope))))
    (string-edit (format "%s: C-c C-c saves, C-c C-k cancels" label)
                 (or value "")
                 (lambda (text)
                   (when (buffer-live-p buf)
                     (with-current-buffer buf (harness-ui-config--save-value key text))))
                 :abort-callback #'ignore)))

;;;; Commands

(defun harness-ui-config--key-at-point ()
  "Return the key of the setting at point, or nil."
  (or (get-text-property (point) 'harness-ui-config-key)
      (let ((w (or (widget-at (point)) (widget-field-at (point)))))
        (while (and w (not (eq (widget-type w) 'harness-ui-config-setting)))
          (setq w (widget-get w :parent)))
        (and w (widget-get w :key)))))

(defun harness-ui-config--require-key ()
  "Return the key of the setting at point or signal."
  (or (harness-ui-config--key-at-point) (user-error "No setting here")))

(defun harness-ui-config-save-setting ()
  "Save the setting at point in the scope shown."
  (interactive)
  (let ((key (harness-ui-config--require-key)))
    (if (harness-ui-config--widget key)
        (harness-ui-config--save key)
      (user-error "Use the buttons of this setting to change it"))))

(defun harness-ui-config-save-all ()
  "Save every edit of the scope shown."
  (interactive)
  (let ((keys (cl-loop for (key . _) in harness-ui-config--widgets
                       when (harness-ui-config--edited-p key) collect key)))
    (if (null keys)
        (message "No edits to save")
      (dolist (key keys) (harness-ui-config--save key)))))

(defun harness-ui-config-revert-setting ()
  "Drop the edit of the setting at point."
  (interactive)
  (let ((key (harness-ui-config--require-key)))
    (remhash (harness-ui-config--edit-key key) harness-ui-config--edited)
    (remhash (harness-ui-config--edit-key key) harness-ui-config--state)
    (harness-ui-config--render)))

(defun harness-ui-config-revert-all ()
  "Drop every edit of the scope shown."
  (interactive)
  (dolist (cell harness-ui-config--widgets)
    (remhash (harness-ui-config--edit-key (car cell)) harness-ui-config--edited)
    (remhash (harness-ui-config--edit-key (car cell)) harness-ui-config--state))
  (harness-ui-config--render))

(defun harness-ui-config-unset-setting ()
  "Remove the project's value of the setting at point, or reset it to its default."
  (interactive)
  (let* ((key (harness-ui-config--require-key))
         (setting (harness-ui-config--setting key)))
    (cond
     ((and (eq harness-ui-config--scope 'project) (not (plist-get setting :project)))
      (user-error "%s does not override it" (capitalize (harness-ui-config--place))))
     ((and (eq harness-ui-config--scope 'global)
           (not (harness-ui-config--true (plist-get setting :secret)))
           (equal (plist-get setting :global) (plist-get setting :standard)))
      (user-error "It already has its default value"))
     (t (harness-ui-config--unset key)))))

(defun harness-ui-config-set-scope (scope)
  "Show and edit the values of SCOPE, `global' or `project'."
  (interactive (list (if (eq harness-ui-config--scope 'global) 'project 'global)))
  (unless (eq scope harness-ui-config--scope)
    (harness-ui-config--snapshot)
    (setq harness-ui-config--widgets nil
          harness-ui-config--scope scope)
    (harness-ui-config--render)
    (force-mode-line-update)
    (message "Editing the %s values" (downcase (harness-ui-config--scope-label scope)))))

(defun harness-ui-config-toggle-scope ()
  "Switch between the Global and the Project scope."
  (interactive)
  (harness-ui-config-set-scope (if (eq harness-ui-config--scope 'global) 'project 'global)))

(defun harness-ui-config-refresh ()
  "Ask the harness for the settings again."
  (interactive)
  (harness-ui-config--load (current-buffer)))

(defun harness-ui-config--advanced-edits ()
  "Return the keys of advanced settings with an edit not saved, globally."
  (let (keys)
    (when harness-ui-config--edited
      (maphash (lambda (ekey _)
                 (when (eq (car ekey) 'global)
                   (let ((setting (harness-ui-config--setting (cdr ekey))))
                     (when (and setting (harness-ui-config--advanced-p setting))
                       (push (cdr ekey) keys)))))
               harness-ui-config--edited))
    keys))

(defun harness-ui-config-toggle-advanced ()
  "Show the advanced settings, or fold them back into one line.
They have a global value only, so showing them shows the Global scope."
  (interactive)
  (cond
   ((eq harness-ui-config--scope 'project)
    (setq harness-ui-config--show-advanced t)
    (harness-ui-config-set-scope 'global))
   ((and harness-ui-config--show-advanced (harness-ui-config--advanced-edits))
    (user-error "Save or revert the edits of advanced settings first"))
   (t
    (setq harness-ui-config--show-advanced (not harness-ui-config--show-advanced))
    (harness-ui-config--render)
    (message (if harness-ui-config--show-advanced "Showing the advanced settings"
               "Advanced settings folded away")))))

(defun harness-ui-config-customize-interface ()
  "Customize the options of the harness interface, which live in this Emacs."
  (interactive)
  (customize-group 'harness-ui))

(defun harness-ui-config--setting-starts ()
  "Return the start of every setting on the page, in order."
  (save-excursion
    (goto-char (point-min))
    (let (out match)
      (while (setq match (text-property-search-forward 'harness-ui-config-key nil
                                                       (lambda (_ v) v) t))
        (push (prop-match-beginning match) out))
      (nreverse out))))

(defun harness-ui-config-next-setting (&optional n)
  "Move to the Nth next setting."
  (interactive "p")
  (let* ((n (or n 1))
         (starts (harness-ui-config--setting-starts))
         (here (point))
         (target (if (> n 0)
                     (nth (1- n) (cl-remove-if (lambda (p) (<= p here)) starts))
                   (nth (1- (- n)) (reverse (cl-remove-if (lambda (p) (>= p here)) starts))))))
    (if (not target)
        (message "No more settings")
      (goto-char target)
      (skip-chars-forward " ")
      ;; Onto the value, when the setting has a widget.
      (let ((end (next-single-property-change (point) 'harness-ui-config-key nil (point-max)))
            (next (ignore-errors (save-excursion (widget-forward 1) (point)))))
        (when (and next (> next (point)) (< next end))
          (goto-char next))))))

(defun harness-ui-config-previous-setting (&optional n)
  "Move to the Nth previous setting."
  (interactive "p")
  (harness-ui-config-next-setting (- (or n 1))))

(defun harness-ui-config-no-edit ()
  "Say where the page can be edited."
  (interactive)
  (user-error "Only values can be edited: TAB moves to the next one"))

(defun harness-ui-config-ret ()
  "Press the button at point, or say where values are edited."
  (interactive)
  (if (get-char-property (point) 'button)
      (widget-button-press (point))
    (harness-ui-config-no-edit)))

;;;; Mode

(defvar harness-ui-config-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map widget-keymap)
    (define-key map [remap self-insert-command] #'harness-ui-config-no-edit)
    (define-key map (kbd "RET") #'harness-ui-config-ret)
    (define-key map (kbd "s") #'harness-ui-config-toggle-scope)
    (define-key map (kbd "a") #'harness-ui-config-toggle-advanced)
    (define-key map (kbd "C") #'harness-ui-config-customize-interface)
    (define-key map (kbd "g") #'harness-ui-config-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "n") #'harness-ui-config-next-setting)
    (define-key map (kbd "p") #'harness-ui-config-previous-setting)
    (define-key map (kbd "d") #'harness-ui-config-unset-setting)
    (define-key map (kbd "C-c C-c") #'harness-ui-config-save-setting)
    (define-key map (kbd "C-c C-k") #'harness-ui-config-revert-setting)
    (define-key map (kbd "C-x C-s") #'harness-ui-config-save-all)
    (define-key map (kbd "SPC") #'scroll-up-command)
    (define-key map (kbd "S-SPC") #'scroll-down-command)
    (define-key map (kbd "DEL") #'scroll-down-command)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-config-mode'.")

(put 'harness-ui-config-mode 'harness-menu-group
     '("Settings"
       ["Page"
        (". s" "Global or project scope" harness-ui-config-toggle-scope)
        (". a" "Show or hide advanced settings" harness-ui-config-toggle-advanced)
        (". C" "Customize the interface" harness-ui-config-customize-interface)
        (". g" "Reload" harness-ui-config-refresh)]
       ["Setting at point"
        ("C-c C-c" "Save it" harness-ui-config-save-setting)
        ("C-c C-k" "Drop the edit" harness-ui-config-revert-setting)
        (". d" "Remove override or reset" harness-ui-config-unset-setting)]))

(define-derived-mode harness-ui-config-mode nil "Settings"
  "Major mode of the harness settings page.
\\<harness-ui-config-mode-map>\\[harness-ui-config-toggle-scope] switches between the Global and the Project scope,
TAB moves between values, RET or \\[harness-ui-config-save-setting] saves the
setting at point and \\[harness-ui-config-save-all] every edit, \\[harness-ui-config-revert-setting] drops an
edit, \\[harness-ui-config-unset-setting] removes the project's value or resets a global
one, and \\[harness-ui-config-refresh] reloads.  \\[harness-ui-config-toggle-advanced] shows or hides the
advanced settings, and \\[harness-ui-config-customize-interface] customizes the interface.

\\{harness-ui-config-mode-map}"
  (setq truncate-lines nil
        buffer-read-only nil
        header-line-format '(:eval (harness-ui-config--header)))
  (setq harness-ui-config--edited (make-hash-table :test 'equal)
        harness-ui-config--state (make-hash-table :test 'equal)
        harness-ui-config--overlays (make-hash-table :test 'equal))
  ;; The look of customize buffers: raised buttons where the display has them.
  (setq-local widget-documentation-face 'harness-settings-doc-face)
  (setq-local widget-button-face custom-button)
  (setq-local widget-button-pressed-face custom-button-pressed)
  (setq-local widget-mouse-face custom-button-mouse)
  (when custom-raised-buttons
    (setq-local widget-push-button-prefix "")
    (setq-local widget-push-button-suffix "")
    (setq-local widget-link-prefix "")
    (setq-local widget-link-suffix ""))
  (add-hook 'kill-buffer-hook #'harness-ui-config--note-unsaved nil t))

(defun harness-ui-config--note-unsaved ()
  "Mention edits that were never saved when the page goes."
  (let ((n 0))
    (when harness-ui-config--edited
      (maphash (lambda (_ _v) (cl-incf n)) harness-ui-config--edited))
    (when (> n 0)
      (message "Harness settings: %d %s not saved" n (if (= n 1) "edit was" "edits were")))))

;;;; Opening

(defun harness-ui-config--context ()
  "Return (CWD . ROOT) for a page about the current buffer.
In a chat buffer that is the session's working directory and project."
  (let* ((session (and harness-ui-session-id (harness-ui-session harness-ui-session-id)))
         (cwd (file-name-as-directory
               (expand-file-name (or (plist-get session :cwd) default-directory))))
         (root (or (plist-get session :project)
                   ;; Remote directories are resolved by the harness, not here.
                   (if (file-remote-p cwd) cwd (harness-files-project-root cwd)))))
    (cons cwd (file-name-as-directory root))))

(defun harness-ui-config--buffer-name (root)
  "Return the name of the settings page of project ROOT."
  (format "*harness settings: %s*" (file-name-nondirectory (directory-file-name root))))

(defun harness-ui-config--buffers ()
  "Return every settings page."
  (cl-remove-if-not (lambda (b) (with-current-buffer b (derived-mode-p 'harness-ui-config-mode)))
                    (buffer-list)))

;;;###autoload
(defun harness-settings (&optional directory scope)
  "Show every harness setting for DIRECTORY's project, Global or Project.
DIRECTORY defaults to the current buffer's directory, or in a chat
buffer to the session's working directory.  SCOPE, `global' or
`project', defaults to the page's current scope, else
`harness-ui-config--default-scope'."
  (interactive)
  (pcase-let* ((`(,cwd . ,root) (if directory
                                    (let ((dir (file-name-as-directory (expand-file-name directory))))
                                      (cons dir (if (file-remote-p dir) dir
                                                  (file-name-as-directory (harness-files-project-root dir)))))
                                  (harness-ui-config--context)))
               (buf (get-buffer-create (harness-ui-config--buffer-name root))))
    (with-current-buffer buf
      (unless (derived-mode-p 'harness-ui-config-mode)
        (harness-ui-config-mode)
        (setq harness-ui-config--scope harness-ui-config--default-scope))
      (when (and scope (not (eq scope harness-ui-config--scope)))
        ;; The edits shown belong to the scope being left.
        (harness-ui-config--snapshot)
        (setq harness-ui-config--widgets nil
              harness-ui-config--scope scope))
      (unless (equal cwd harness-ui-config--cwd)
        (setq harness-ui-config--data nil))
      (setq harness-ui-config--cwd cwd
            harness-ui-config--root root
            default-directory cwd)
      ;; What is known shows at once; the answer to the reload follows.
      (harness-ui-config--render))
    (harness-ui-display-view buf)
    (harness-ui-config--load buf)
    buf))

;;;; Live refresh

(defun harness-ui-config--model-ids ()
  "Return the ids of the models in the UI's catalogue."
  (let (ids)
    (maphash (lambda (id _) (push id ids)) harness-ui--models)
    (sort ids #'string<)))

(defun harness-ui-config--on-event (event _args)
  "Reload every settings page after a setting changed (EVENT)."
  (when (equal event "config/changed")
    (mapc #'harness-ui-config--reload-soon (harness-ui-config--buffers))))

(defun harness-ui-config--redraw-all ()
  "Fetch every settings page again, after a reload or reconnect.
Shortly after: the hook runs as a new connection opens, before its
socket is up."
  (mapc #'harness-ui-config--reload-soon (harness-ui-config--buffers)))

;;;; Module

(defun harness-ui-config--init ()
  "Wire the settings page into the UI."
  (add-hook 'harness-ui-event-functions #'harness-ui-config--on-event)
  (add-hook 'harness-ui-redraw-hook #'harness-ui-config--redraw-all)
  (define-key harness-ui-map (kbd "S") #'harness-settings))

(harness-define-module 'ui-config
  :doc "Settings page: every harness setting, edited globally or for the project."
  :requires '(ui)
  :init #'harness-ui-config--init)

(provide 'harness-ui-config)
;;; harness-ui-config.el ends here
