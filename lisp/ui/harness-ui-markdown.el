;;; harness-ui-markdown.el --- Built-in Markdown renderer  -*- lexical-binding: t; -*-

;;; Commentary:

;; Turns Markdown into a propertized string using only Emacs faces and
;; major modes: headings, paragraphs, emphasis, inline code, fenced
;; code blocks fontified by the language's major mode, lists with
;; hanging indentation (continuation lines wrap under the item text),
;; block quotes, links as buttons, horizontal rules and simple tables.
;; The renderer is pure: `harness-ui-markdown-render' returns a string
;; the caller inserts, so it can be used for streaming re-renders.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup harness-ui-markdown nil
  "Markdown rendering for the harness."
  :group 'harness-ui)

(defface harness-md-heading-1 '((t :inherit bold :height 1.3))
  "Level 1 heading." :group 'harness-ui-markdown)
(defface harness-md-heading-2 '((t :inherit bold :height 1.15))
  "Level 2 heading." :group 'harness-ui-markdown)
(defface harness-md-heading-3 '((t :inherit bold :height 1.05))
  "Level 3 heading." :group 'harness-ui-markdown)
(defface harness-md-heading-4 '((t :inherit bold))
  "Deeper headings." :group 'harness-ui-markdown)
(defface harness-md-code '((t :inherit fixed-pitch-serif :background unspecified))
  "Inline code." :group 'harness-ui-markdown)
(defface harness-md-code-block
  '((((background light)) :background "#f3f4f6" :extend t)
    (((background dark)) :background "#20242b" :extend t))
  "Fenced code block background." :group 'harness-ui-markdown)
(defface harness-md-code-lang '((t :inherit shadow :height 0.85))
  "Language label of a code block." :group 'harness-ui-markdown)
(defface harness-md-quote '((t :inherit (italic shadow)))
  "Block quotes." :group 'harness-ui-markdown)
(defface harness-md-quote-bar '((t :inherit shadow))
  "The bar before a block quote line." :group 'harness-ui-markdown)
(defface harness-md-bullet '((t :inherit font-lock-keyword-face))
  "List bullets." :group 'harness-ui-markdown)
(defface harness-md-rule '((t :inherit shadow :strike-through t))
  "Horizontal rules." :group 'harness-ui-markdown)
(defface harness-md-table-header '((t :inherit bold))
  "Table header cells." :group 'harness-ui-markdown)
(defface harness-md-strike '((t :strike-through t))
  "Struck text." :group 'harness-ui-markdown)

(defcustom harness-ui-markdown-language-modes
  '(("elisp" . emacs-lisp-mode) ("emacs-lisp" . emacs-lisp-mode) ("lisp" . lisp-mode)
    ("sh" . sh-mode) ("bash" . sh-mode) ("shell" . sh-mode) ("zsh" . sh-mode)
    ("js" . js-mode) ("javascript" . js-mode) ("ts" . typescript-ts-mode) ("typescript" . typescript-ts-mode)
    ("json" . js-json-mode) ("py" . python-mode) ("python" . python-mode)
    ("c" . c-mode) ("cpp" . c++-mode) ("c++" . c++-mode) ("rust" . rust-ts-mode) ("go" . go-ts-mode)
    ("html" . html-mode) ("xml" . nxml-mode) ("css" . css-mode) ("yaml" . yaml-ts-mode)
    ("toml" . conf-toml-mode) ("ini" . conf-mode) ("diff" . diff-mode) ("patch" . diff-mode)
    ("sql" . sql-mode) ("makefile" . makefile-mode) ("org" . org-mode) ("tex" . latex-mode)
    ("ruby" . ruby-mode) ("java" . java-mode) ("kotlin" . kotlin-ts-mode))
  "Fenced block language names mapped to major modes."
  :type '(alist :key-type string :value-type symbol) :group 'harness-ui-markdown)

(defconst harness-ui-markdown--fontify-limit 40000
  "Code blocks longer than this many characters are not fontified.")

;;;; Inline rendering

(defun harness-ui-markdown--add-face (string face)
  (let ((s (copy-sequence string)))
    (add-face-text-property 0 (length s) face t s)
    s))

;;;; Links

(defvar harness-ui-markdown-link-map (make-sparse-keymap)
  "Keymap of the links in rendered Markdown.")

;; Filled at top level, not in the `defvar', so a reload updates the map.
(let ((map harness-ui-markdown-link-map))
  ;; A click on a link only opens it.  The `follow-link' property, under
  ;; `mouse-1-click-follows-link', turns a quick `mouse-1' into `mouse-2',
  ;; so `mouse-2' has to open it too: left unbound, it fell through to the
  ;; global `mouse-yank-primary', which pasted the primary selection --
  ;; whatever text was selected last, anywhere -- into the response.
  (define-key map [mouse-1] #'harness-ui-markdown-follow-link)
  (define-key map [mouse-2] #'harness-ui-markdown-follow-link)
  (define-key map (kbd "RET") #'harness-ui-markdown-follow-link)
  ;; The first click of a double or triple click opened it; unbound, the
  ;; next ones would run as single clicks and open it again.
  (dolist (key '([double-mouse-1] [triple-mouse-1] [double-mouse-2] [triple-mouse-2]))
    (define-key map key #'ignore)))

(defun harness-ui-markdown--link (text url)
  "Return TEXT as a link to URL."
  (propertize text 'face 'link 'mouse-face 'highlight
              'help-echo url 'harness-url url
              'follow-link t
              'keymap harness-ui-markdown-link-map))

(defun harness-ui-markdown-follow-link (&optional event)
  "Open the link at point, or the one mouse EVENT clicked on.
The buffer the link is in stays as it is; `harness-ui-markdown-open-link'
says what opening does."
  (interactive (list last-nonmenu-event))
  (let ((posn (and (mouse-event-p event) (event-start event))))
    ;; From the window clicked in, so a file opens beside it, not over it.
    (when (and posn (window-live-p (posn-window posn)))
      (select-window (posn-window posn)))
    (let ((url (get-text-property (or (and posn (posn-point posn)) (point)) 'harness-url)))
      (unless url (user-error "No link here"))
      (harness-ui-markdown-open-link url))))

(defun harness-ui-markdown--url-p (target)
  "Non-nil when link TARGET is a URL to browse, not a file to visit."
  (and (string-match "\\`\\([a-zA-Z][a-zA-Z0-9+.-]+\\):" target)
       (not (equal (downcase (match-string 1 target)) "file"))
       ;; Not "notes.md:12", a file name and a line.
       (not (string-match-p "\\`[^:/]+:[0-9]+\\(?::[0-9]+\\)?\\'" target))))

(defun harness-ui-markdown--link-file (target)
  "Return (FILE . LINE) for link TARGET, a file name or a file: URL.
FILE is expanded in `default-directory', or nil when TARGET names none,
as a bare \"#fragment\" does.  LINE is the line a \"#L12\" or \":12\"
suffix names, else nil; any other fragment is dropped."
  (let ((name target) (line nil))
    (cond ((or (string-match "#L\\([0-9]+\\)[^#]*\\'" name)
               (string-match ":\\([0-9]+\\)\\(?::[0-9]+\\)?\\'" name))
           (setq line (string-to-number (match-string 1 name))
                 name (substring name 0 (match-beginning 0))))
          ((string-match "#.*\\'" name)
           (setq name (substring name 0 (match-beginning 0)))))
    ;; The fragment is off first: a "#" a file: URL's path holds is %23.
    (when (string-match "\\`file:\\(?://[^/]*\\)?" name)
      (setq name (decode-coding-string (url-unhex-string (substring name (match-end 0))) 'utf-8)))
    (cons (and (not (string-empty-p name)) (expand-file-name name)) line)))

(defun harness-ui-markdown-open-link (target)
  "Open link TARGET, leaving the buffer the link is in alone.
A URL -- https:, mailto: and the like -- goes to `browse-url'.  Anything
else is a file: a file: URL, or a file name, absolute or relative to
`default-directory'.  It opens in another window, at the line a \"#L12\"
or \":12\" suffix names."
  (if (harness-ui-markdown--url-p target)
      (browse-url target)
    (pcase-let ((`(,file . ,line) (harness-ui-markdown--link-file target)))
      (unless (and file (file-exists-p file))
        (user-error "No such file: %s" (or file target)))
      (find-file-other-window file)
      (when line
        (goto-char (point-min))
        (forward-line (1- line))))))

(defconst harness-ui-markdown--inline-regexp
  (rx (or (group-n 1 "`" (+? (not "`")) "`")                          ; code
          (group-n 2 "**" (+? nonl) "**")                              ; bold
          (group-n 3 "__" (+? nonl) "__")                              ; bold
          (group-n 4 "~~" (+? nonl) "~~")                              ; strike
          (group-n 5 "[" (+? (not "]")) "](" (+? (not ")")) ")")       ; link
          (group-n 6 (or bol (not (any alnum "*"))) "*" (+? (not (any "*\n"))) "*")  ; italic
          (group-n 7 (or bol (not (any alnum "_"))) "_" (+? (not (any "_\n"))) "_")  ; italic
          (group-n 8 "<" (+? (any alnum ":/._~?#=&%+-")) ">")          ; autolink
          (group-n 9 (or "http://" "https://") (+ (any alnum ":/._~?#=&%+-@")))))) ; bare url

(defun harness-ui-markdown-inline (text)
  "Render inline Markdown in TEXT and return a propertized string."
  (let ((pos 0) (parts nil))
    (while (and (< pos (length text)) (string-match harness-ui-markdown--inline-regexp text pos))
      (let ((start (match-beginning 0)) (end (match-end 0)) (piece nil))
        (cond
         ((match-beginning 1)
          (setq piece (harness-ui-markdown--add-face (substring text (1+ start) (1- end)) 'harness-md-code)))
         ((or (match-beginning 2) (match-beginning 3))
          (setq piece (harness-ui-markdown--add-face
                       (harness-ui-markdown-inline (substring text (+ start 2) (- end 2))) 'bold)))
         ((match-beginning 4)
          (setq piece (harness-ui-markdown--add-face (substring text (+ start 2) (- end 2)) 'harness-md-strike)))
         ((match-beginning 5)
          ;; "[LABEL](URL)": LABEL holds no "]", so the first "](" splits it.
          (let* ((m (substring text start end))
                 (sep (string-search "](" m)))
            (setq piece (harness-ui-markdown--link (substring m 1 sep) (substring m (+ sep 2) -1)))))
         ((or (match-beginning 6) (match-beginning 7))
          ;; The group may include a leading delimiter character; keep it plain.
          (let* ((m (substring text start end))
                 (lead (if (memq (aref m 0) '(?* ?_)) "" (substring m 0 1)))
                 (inner (substring m (1+ (length lead)) (1- (length m)))))
            (setq piece (concat lead (harness-ui-markdown--add-face (harness-ui-markdown-inline inner) 'italic)))))
         ((match-beginning 8)
          (let ((url (substring text (1+ start) (1- end))))
            (setq piece (harness-ui-markdown--link url url))))
         ((match-beginning 9)
          (let ((url (substring text start end)))
            (setq piece (harness-ui-markdown--link url url)))))
        (push (substring text pos start) parts)
        (push piece parts)
        (setq pos end)))
    (push (substring text pos) parts)
    (apply #'concat (nreverse parts))))

;;;; Block rendering

(defun harness-ui-markdown--fontify-code (code lang)
  "Return CODE fontified with the major mode for LANG when possible."
  (let ((mode (and lang (cdr (assoc (downcase lang) harness-ui-markdown-language-modes)))))
    (if (and mode (fboundp mode) (< (length code) harness-ui-markdown--fontify-limit))
        (condition-case nil
            (with-temp-buffer
              (insert code)
              (delay-mode-hooks (funcall mode))
              (let ((inhibit-message t))
                (font-lock-ensure))
              ;; Font-lock leaves `face' properties; keep them as `font-lock-face' too.
              (let ((s (buffer-string)))
                (remove-text-properties 0 (length s) '(fontified nil) s)
                s))
          (error code))
      code)))

(defun harness-ui-markdown--code-block (code lang)
  (let* ((body (harness-ui-markdown--fontify-code (string-trim-right code) lang))
         (label (if (and lang (not (string-empty-p lang)))
                    (propertize (concat lang "\n") 'face 'harness-md-code-lang)
                  ""))
         (text (concat label body "\n")))
    (add-face-text-property 0 (length text) 'harness-md-code-block t text)
    (propertize text 'harness-md-block 'code 'wrap-prefix "" 'line-prefix "  ")))

(defun harness-ui-markdown--wrap (text prefix &optional first-prefix)
  "Return TEXT with hanging indentation PREFIX (FIRST-PREFIX on line one)."
  (let ((s (concat (or first-prefix prefix) text)))
    (add-text-properties 0 (length s) (list 'wrap-prefix prefix) s)
    s))

(defun harness-ui-markdown--table (lines)
  "Render table LINES (strings with | separators) as an aligned text table.
Cells are measured as rendered: the markers of inline markup, such as
the backquotes of `code', take no room."
  (let* ((rows (mapcar (lambda (l)
                         (mapcar #'string-trim
                                 (split-string (string-trim (string-trim l) "|" "|") "|")))
                       lines))
         (sep-index (cl-position-if (lambda (r) (cl-every (lambda (c) (string-match-p "\\`:?-+:?\\'" c)) r)) rows))
         (rows (if sep-index (append (seq-take rows sep-index) (seq-drop rows (1+ sep-index))) rows))
         (rows (mapcar (lambda (r) (mapcar #'harness-ui-markdown-inline r)) rows))
         (ncols (apply #'max 1 (mapcar #'length rows)))
         (widths (make-vector ncols 0)))
    (dolist (r rows)
      (cl-loop for c in r for i from 0
               do (aset widths i (max (aref widths i) (string-width c)))))
    (let ((out nil) (first (and sep-index t)))
      (dolist (r rows)
        (let ((cells (cl-loop for i from 0 below ncols
                              for c = (or (nth i r) "")
                              collect (concat c (make-string (- (aref widths i) (string-width c)) ?\s)))))
          (let ((line (concat " " (string-join cells " │ ") "\n")))
            (when first
              (add-face-text-property 0 (length line) 'harness-md-table-header t line)
              (setq first nil))
            (push line out))))
      (propertize (apply #'concat (nreverse out)) 'harness-md-block 'table))))

(defun harness-ui-markdown-render (text)
  "Render Markdown TEXT into a propertized string."
  (let ((lines (split-string (or text "") "\n"))
        (out nil)
        (para nil))
    (cl-labels
        ((flush-para ()
           ;; Every block branch calls this between matching its line and
           ;; reading the groups, so the inline rendering must leave the
           ;; match data alone.
           (when para
             (save-match-data
               (push (concat (harness-ui-markdown-inline (string-join (nreverse para) " ")) "\n") out))
             (setq para nil)))
         (emit (s) (push s out)))
      (while lines
        (let ((line (pop lines)))
          (cond
           ;; Fenced code block
           ((string-match "\\`[ ]\\{0,3\\}\\(```+\\|~~~+\\)[ ]*\\([A-Za-z0-9_+.-]*\\)" line)
            (flush-para)
            (let ((fence (match-string 1 line)) (lang (match-string 2 line)) (code nil))
              (while (and lines (not (string-match-p (concat "\\`[ ]\\{0,3\\}" (regexp-quote fence) "[ ]*\\'") (car lines))))
                (push (pop lines) code))
              (pop lines)
              (emit (harness-ui-markdown--code-block (string-join (nreverse code) "\n") lang))))
           ;; Heading
           ((string-match "\\`\\(#\\{1,6\\}\\)[ \t]+\\(.*?\\)[ \t#]*\\'" line)
            (flush-para)
            (let* ((level (length (match-string 1 line)))
                   (face (pcase level (1 'harness-md-heading-1) (2 'harness-md-heading-2)
                                (3 'harness-md-heading-3) (_ 'harness-md-heading-4))))
              (emit (concat (harness-ui-markdown--add-face (harness-ui-markdown-inline (match-string 2 line)) face) "\n"))))
           ;; Horizontal rule
           ((string-match-p "\\`[ ]\\{0,3\\}\\([-*_]\\)\\([ ]*\\1\\)\\{2,\\}[ ]*\\'" line)
            (flush-para)
            (emit (propertize (concat (make-string 40 ?\s) "\n") 'face 'harness-md-rule)))
           ;; Table (a line with pipes followed by a separator line)
           ((and (string-match-p "|" line) lines
                 (string-match-p "\\`[ ]*|?[ ]*:?-+:?[ ]*\\(|[ ]*:?-+:?[ ]*\\)*|?[ ]*\\'" (car lines)))
            (flush-para)
            (let ((rows (list line)))
              (while (and lines (string-match-p "|" (car lines)))
                (push (pop lines) rows))
              (emit (harness-ui-markdown--table (nreverse rows)))))
           ;; Block quote
           ((string-match "\\`[ ]\\{0,3\\}>[ ]?\\(.*\\)\\'" line)
            (flush-para)
            (let ((quoted (list (match-string 1 line))))
              (while (and lines (string-match "\\`[ ]\\{0,3\\}>[ ]?\\(.*\\)\\'" (car lines)))
                (push (match-string 1 (pop lines)) quoted))
              (let ((inner (harness-ui-markdown-render (string-join (nreverse quoted) "\n"))))
                (dolist (l (split-string (string-trim-right inner "\n") "\n"))
                  (emit (concat (propertize "┃ " 'face 'harness-md-quote-bar)
                                (harness-ui-markdown--add-face l 'harness-md-quote) "\n"))))))
           ;; List item
           ((string-match "\\`\\([ \t]*\\)\\([-*+]\\|[0-9]+[.)]\\)[ \t]+\\(.*\\)\\'" line)
            (flush-para)
            (let* ((indent (string-width (match-string 1 line)))
                   (marker (match-string 2 line))
                   (body (list (match-string 3 line)))
                   (bullet (if (string-match-p "\\`[0-9]" marker) (concat marker " ") "• "))
                   (prefix (make-string (+ indent (string-width bullet)) ?\s)))
              ;; Continuation lines: indented more than the item, not a new item.
              (while (and lines
                          (not (string-blank-p (car lines)))
                          (not (string-match-p "\\`[ \t]*\\([-*+]\\|[0-9]+[.)]\\)[ \t]+" (car lines)))
                          (string-match-p "\\`[ \t]+" (car lines)))
                (push (string-trim (pop lines)) body))
              (emit (harness-ui-markdown--wrap
                     (concat (harness-ui-markdown-inline (string-join (nreverse body) " ")) "\n")
                     prefix
                     (concat (make-string indent ?\s) (propertize bullet 'face 'harness-md-bullet))))))
           ;; Blank line
           ((string-blank-p line)
            (flush-para)
            (when (and out (not (string-suffix-p "\n\n" (car out))))
              (emit "\n")))
           ;; Paragraph text
           (t (push line para)))))
      (flush-para))
    (let ((s (apply #'concat (nreverse out))))
      (string-trim-right s "\n+"))))

(defun harness-ui-markdown-insert (text)
  "Insert Markdown TEXT rendered at point."
  (insert (harness-ui-markdown-render text)))

(provide 'harness-ui-markdown)
;;; harness-ui-markdown.el ends here
