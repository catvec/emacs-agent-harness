;;; harness-ui-markdown.el --- Built-in Markdown renderer  -*- lexical-binding: t; -*-

;;; Commentary:

;; Turns Markdown into a propertized string using only Emacs faces and
;; major modes: headings, paragraphs, emphasis, inline code, fenced
;; code blocks fontified by the language's major mode, lists with
;; hanging indentation (continuation lines wrap under the item text),
;; block quotes, links as buttons, horizontal rules and simple tables.
;; The renderer is pure: `harness-ui-markdown-render' returns a string
;; the caller inserts, so it can be used for streaming re-renders.
;;
;; A link to something in the harness -- a session, a message, a tool
;; call, a task, a thread of a review (harness-links.el) -- is a link
;; like any other, written [text](harness:...), <harness:...> or bare;
;; the two that have no words of their own read as what they name.  The
;; renderer does not know what they name or where they go: the UI module
;; that does (ui-linking) sets `harness-ui-markdown-harness-link-function'
;; to follow one, and `harness-ui-markdown-link-describe-function' to say
;; what one is.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-links)

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
  "Return a copy of STRING with FACE added to the faces of all of it."
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

(defun harness-ui-markdown--link (text url &optional help)
  "Return TEXT as a link to URL, whose tooltip is HELP, by default URL."
  (propertize text 'face 'link 'mouse-face 'highlight
              'help-echo (or help url) 'harness-url url
              'follow-link t
              'keymap harness-ui-markdown-link-map))

(defvar harness-ui-markdown-harness-link-function nil
  "Function that follows a harness link, or nil when none can.
Called with the link's URL (`harness-links-p') by
`harness-ui-markdown-open-link', in the buffer the link is in.  The
UI module that knows what a session, a message or a thread is sets it
\(ui-linking); with none, following one is an error that says so.")

(defvar harness-ui-markdown-link-describe-function nil
  "Function that says what a harness link is, or nil.
Called with the link's URL, it returns a plist: `:label', the words to
show for a link that has none of its own (an autolink or a bare one),
and `:help', its tooltip; either may be left out.  It may name what the
link goes to -- the session's name -- which the renderer cannot know.")

(defun harness-ui-markdown--describe (url)
  "Return what `harness-ui-markdown-link-describe-function' says of URL, or nil."
  (when harness-ui-markdown-link-describe-function
    (condition-case nil
        (funcall harness-ui-markdown-link-describe-function url)
      (error nil))))

(defun harness-ui-markdown--harness-link (url &optional label)
  "Return a link to the harness link URL, showing LABEL.
Without LABEL it shows words that stand for what URL names.  The tooltip
says what the click opens."
  (let* ((described (harness-ui-markdown--describe url))
         (parsed (harness-links-parse url))
         (what (or (plist-get described :label)
                   (and parsed (harness-links-label parsed))
                   url)))
    (harness-ui-markdown--link
     (or label what) url
     (or (plist-get described :help)
         (if parsed
             (format "mouse-1, RET: open %s" what)
           (format "%s: not a link to anything in the harness" url))))))

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
A harness link -- a session, a message, a tool call, a thread -- is
followed by `harness-ui-markdown-harness-link-function', in this buffer.
A URL -- https:, mailto: and the like -- goes to `browse-url'.  Anything
else is a file: a file: URL, or a file name, absolute or relative to
`default-directory'.  It opens in another window, at the line a \"#L12\"
or \":12\" suffix names."
  (cond
   ((harness-links-p target)
    (if harness-ui-markdown-harness-link-function
        (funcall harness-ui-markdown-harness-link-function target)
      (user-error "Links to sessions, messages and threads need the linking module")))
   ((harness-ui-markdown--url-p target)
    (browse-url target))
   (t
    (pcase-let ((`(,file . ,line) (harness-ui-markdown--link-file target)))
      (unless (and file (file-exists-p file))
        (user-error "No such file: %s" (or file target)))
      (find-file-other-window file)
      (when line
        (goto-char (point-min))
        (forward-line (1- line)))))))

;; Emphasis, as Markdown has it, has text against its markers: the one
;; that opens it is not followed by a blank, the one that closes it not
;; preceded by one, and an underscore does not close it before a letter
;; or a digit.  Else the marker is a star, an underscore, which technical
;; text is full of: "2 * 3 * 4", "char *p and char *q", "*args and
;; **kwargs", "*.el and *.py", "a _ b _ c", "_private_method".  Read
;; without that rule, the text between two of them turned italic and the
;; markers vanished.  The regexp finds what could be emphasis, in time
;; that stays linear whatever the text holds; `harness-ui-markdown--emphasis-p'
;; says whether it is, and what is not has its first character taken as
;; text, the rest looked at again.
(defconst harness-ui-markdown--inline-regexp
  (rx (or (group-n 1 "`" (+? (not "`")) "`")                          ; code
          (group-n 2 "**" (+? nonl) "**")                              ; bold
          (group-n 3 "__" (+? nonl) "__")                              ; bold
          (group-n 4 "~~" (+? nonl) "~~")                              ; strike
          (group-n 5 "[" (+? (not "]")) "](" (+? (not ")")) ")")       ; link
          (group-n 6 (or bol (not (any alnum "*"))) "*" (+? (not (any "*\n"))) "*")  ; italic
          (group-n 7 (or bol (not (any alnum "_"))) "_" (+? (not (any "_\n"))) "_")  ; italic
          ;; An autolink is a URL in angle brackets, so it names a scheme:
          ;; "List<Foo>" is not one, and its brackets stay.
          (group-n 8 "<" (any alpha) (* (any alnum "+.-")) ":" (+? (any alnum ":/._~?#=&%+@-")) ">") ; autolink
          (group-n 9 (or "http://" "https://") (+ (any alnum ":/._~?#=&%+-@")))   ; bare url
          (group-n 10 (regexp harness-links-bare-regexp)))))                      ; bare harness link

(defun harness-ui-markdown--emphasis-p (text inner-start inner-end &optional word-after)
  "Return non-nil when TEXT from INNER-START to INNER-END is emphasised.
That is when no blank is against either marker.  With WORD-AFTER, the
closing marker, an underscore, is at INNER-END too, and no letter or
digit may follow it: a name with underscores is a name."
  (and (< inner-start inner-end)
       (not (memq (aref text inner-start) '(?\s ?\t ?\n)))
       (not (memq (aref text (1- inner-end)) '(?\s ?\t ?\n)))
       (or (not word-after)
           (>= (1+ inner-end) (length text))
           (not (string-match-p "[[:alnum:]]" (string (aref text (1+ inner-end))))))))

(defun harness-ui-markdown-inline (text)
  "Render inline Markdown in TEXT and return a propertized string."
  (let ((pos 0) (parts nil))
    (while (and (< pos (length text)) (string-match harness-ui-markdown--inline-regexp text pos))
      (let* ((start (match-beginning 0)) (end (match-end 0)) (piece nil)
             ;; The italic groups may begin with the character before the
             ;; marker, which stays plain.
             (lead (cond ((match-beginning 6) (if (eq (aref text start) ?*) 0 1))
                         ((match-beginning 7) (if (eq (aref text start) ?_) 0 1))
                         (t 0)))
             (emphasis (cond ((or (match-beginning 2) (match-beginning 3))
                              (harness-ui-markdown--emphasis-p text (+ start 2) (- end 2)))
                             ((or (match-beginning 6) (match-beginning 7))
                              (harness-ui-markdown--emphasis-p
                               text (+ start lead 1) (1- end) (and (match-beginning 7) t)))
                             ;; Not a link inside a longer word or address.
                             ((match-beginning 10)
                              (not (and (> start 0)
                                        (harness-links-url-char-p (aref text (1- start))))))
                             (t t))))
        (if (not emphasis)
            ;; Not emphasis: a star, an underscore, and the text after it is
            ;; read again.
            (progn (push (substring text pos (1+ start)) parts)
                   (setq pos (1+ start)))
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
                   (sep (string-search "](" m))
                   (url (substring m (+ sep 2) -1)))
              (setq piece (if (harness-links-p (string-trim url))
                              (harness-ui-markdown--harness-link (string-trim url) (substring m 1 sep))
                            (harness-ui-markdown--link (substring m 1 sep) url)))))
           ((or (match-beginning 6) (match-beginning 7))
            (setq piece (concat (substring text start (+ start lead))
                                (harness-ui-markdown--add-face
                                 (harness-ui-markdown-inline (substring text (+ start lead 1) (1- end)))
                                 'italic))))
           ((match-beginning 8)
            (let ((url (substring text (1+ start) (1- end))))
              (setq piece (if (harness-links-p url)
                              (harness-ui-markdown--harness-link url)
                            (harness-ui-markdown--link url url)))))
           ((match-beginning 9)
            (let ((url (substring text start end)))
              (setq piece (harness-ui-markdown--link url url))))
           ((match-beginning 10)
            ;; A full stop or a colon that ends the sentence is not the link's.
            (setq end (harness-links-trim-bare text start end))
            (setq piece (harness-ui-markdown--harness-link (substring text start end)))))
          (push (substring text pos start) parts)
          (push piece parts)
          (setq pos end))))
    (push (substring text pos) parts)
    (apply #'concat (nreverse parts))))

;;;; Block rendering

(defvar harness-ui-markdown--fontified (make-hash-table :test 'equal)
  "(MODE . CODE) -> CODE fontified in MODE, for the code blocks rendered lately.
A message streaming in is rendered again and again, all of it, and
fontifying a block runs its major mode in a buffer of its own: the
blocks it finished come from here instead.")

(defvar harness-ui-markdown--fontified-size 0
  "Characters of code `harness-ui-markdown--fontified' holds.")

(defconst harness-ui-markdown--fontified-max 1000000
  "Characters of code `harness-ui-markdown--fontified' holds before it starts over.")

(defun harness-ui-markdown--fontify-code (code lang)
  "Return CODE fontified with the major mode for LANG when possible.
The string may be shared with other renderings: change a copy of it."
  (let ((mode (and lang (cdr (assoc (downcase lang) harness-ui-markdown-language-modes)))))
    (if (and mode (fboundp mode) (< (length code) harness-ui-markdown--fontify-limit))
        (let ((key (cons mode code)))
          (or (gethash key harness-ui-markdown--fontified)
              (let ((fontified (harness-ui-markdown--fontify-in code mode)))
                (when (> (cl-incf harness-ui-markdown--fontified-size (length code))
                         harness-ui-markdown--fontified-max)
                  (clrhash harness-ui-markdown--fontified)
                  (setq harness-ui-markdown--fontified-size (length code)))
                (puthash key fontified harness-ui-markdown--fontified))))
      code)))

(defun harness-ui-markdown--fontify-in (code mode)
  "Return CODE fontified by major MODE, or CODE itself when that fails."
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
    (error code)))

(defun harness-ui-markdown--code-block (code lang)
  "Render fenced block CODE, in language LANG (a string or nil), as text.
The code is fontified for LANG where possible and indented, under a
line naming LANG when it is given."
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

(defconst harness-ui-markdown--table-min-column 6
  "Narrowest a table column gets when a table is fitted to a width.
Below this cells would wrap into single words.")

(defvar harness-ui-markdown-table-width nil
  "Columns a Markdown table may take at most, or nil for its natural width.
A table wider than this is wrapped cell by cell, so the columns stay
aligned and it fits a window instead of wrapping mid-cell.  A caller
that knows how much room its window gives binds this around
`harness-ui-markdown-render'.")

(defvar harness-ui-markdown-hard-breaks nil
  "Non-nil keeps each line break inside a paragraph, as GitHub comments do.
Markdown joins the lines of a paragraph with spaces, which suits what a
model writes; a person typing means a line break as one.  A caller
rendering what a person typed binds this around
`harness-ui-markdown-render'.  Only paragraphs change, a quote's
among them: lists, code blocks and tables render the same either way.")

(defun harness-ui-markdown--cell-words (cell)
  "Return the words of CELL, a rendered cell, as propertized strings."
  (let ((words nil) (start 0) (len (length cell)))
    (while (< start len)
      (let ((end (or (string-search " " cell start) len)))
        (when (> end start)
          (push (substring cell start end) words))
        (setq start (1+ end))))
    (nreverse words)))

(defun harness-ui-markdown--break-word (word width)
  "Return WORD as propertized pieces, none wider than WIDTH columns."
  (let ((pieces nil) (pos 0) (len (length word)))
    (while (< pos len)
      (let ((end pos) (used 0))
        (while (and (< end len)
                    (<= (+ used (char-width (aref word end))) width))
          (setq used (+ used (char-width (aref word end)))
                end (1+ end)))
        (when (= end pos)
          ;; A single character wider than the column is taken whole.
          (setq end (1+ pos)))
        (push (substring word pos end) pieces)
        (setq pos end)))
    (nreverse pieces)))

(defun harness-ui-markdown--wrap-cell (cell width)
  "Return CELL, a rendered cell, as lines none wider than WIDTH columns.
Words too wide for the column are broken; the lines keep CELL's faces."
  (let ((lines nil) (line "") (line-width 0))
    (cl-flet ((flush ()
                (push line lines)
                (setq line "" line-width 0)))
      (dolist (word (harness-ui-markdown--cell-words cell))
        (dolist (piece (if (<= (string-width word) width)
                           (list word)
                         (harness-ui-markdown--break-word word width)))
          (let ((piece-width (string-width piece)))
            (cond ((= line-width 0)
                   (setq line piece line-width piece-width))
                  ((<= (+ line-width 1 piece-width) width)
                   (setq line (concat line " " piece)
                         line-width (+ line-width 1 piece-width)))
                  (t (flush)
                     (setq line piece line-width piece-width))))))
      (flush))
    (nreverse lines)))

(defun harness-ui-markdown--fit-widths (widths room)
  "Return WIDTHS (a vector) shrunk to sum to at most ROOM.
The widest column gives way first; none goes below
`harness-ui-markdown--table-min-column'."
  (let ((widths (copy-sequence widths))
        (min harness-ui-markdown--table-min-column))
    (cl-block nil
      (while (> (apply #'+ (append widths nil)) room)
        (let* ((list (append widths nil))
               (i (cl-position (apply #'max list) list))
               (roomy (cl-count-if (lambda (w) (> w min)) list)))
          (when (zerop roomy) (cl-return))
          (let ((step (max 1 (ceiling (- (apply #'+ list) room) roomy))))
            (aset widths i (max min (- (aref widths i) step)))))))
    widths))

(defun harness-ui-markdown--table (lines)
  "Render table LINES (strings with | separators) as an aligned text table.
Cells are measured as rendered: the markers of inline markup, such as
the backquotes of `code', take no room.  A table wider than
`harness-ui-markdown-table-width', when that is non-nil, is wrapped cell
by cell so it fits a window with its columns still aligned; a column is
never narrower than `harness-ui-markdown--table-min-column'."
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
    (when harness-ui-markdown-table-width
      (setq widths (harness-ui-markdown--fit-widths
                    widths
                    (max harness-ui-markdown--table-min-column
                         (- harness-ui-markdown-table-width
                            1 (* 3 (1- ncols)))))))
    (let ((out nil) (first (and sep-index t)))
      (dolist (r rows)
        (let* ((cells (cl-loop for i from 0 below ncols
                               for c = (or (nth i r) "")
                               collect (harness-ui-markdown--wrap-cell c (max 1 (aref widths i)))))
               (height (apply #'max 1 (mapcar #'length cells))))
          (dotimes (line height)
            (let ((text (concat
                         " "
                         (string-join
                          (cl-loop for i from 0 below ncols
                                   for piece = (or (nth line (nth i cells)) "")
                                   collect (concat piece (make-string (max 0 (- (aref widths i) (string-width piece))) ?\s)))
                          " │ ")
                         "\n")))
              (when first
                (add-face-text-property 0 (length text) 'harness-md-table-header t text))
              (push text out)))
          (setq first nil)))
      (propertize (apply #'concat (nreverse out)) 'harness-md-block 'table))))

(defun harness-ui-markdown--rule-p (line)
  "Non-nil when LINE is a Markdown horizontal rule.
Three or more of the same \"-\", \"*\" or \"_\", spaces allowed between
them, up to three leading spaces.  Checked by hand rather than with the
equivalent regexp, which backtracks its way through a line of a hundred
thousand characters until the regexp engine gives up with a \"Stack
overflow in regexp matcher\": a single enormous line, such as a message
the harness sends itself, would take the whole rendering down."
  (let ((end (length line))
        (i 0)
        (char nil)
        (count 0)
        (rule t))
    ;; Up to three leading spaces; a fourth makes it an indented code line.
    (while (and (< i end) (eq (aref line i) ?\s) (< i 3))
      (cl-incf i))
    (if (and (< i end) (eq (aref line i) ?\s))
        nil
      (while (and rule (< i end))
        (let ((c (aref line i)))
          (cond ((memq c '(?- ?* ?_))
                 (setq char (or char c))
                 (if (eq c char) (cl-incf count) (setq rule nil)))
                ((not (eq c ?\s)) (setq rule nil))))
        (cl-incf i))
      (and rule (>= count 3)))))

(defun harness-ui-markdown-render (text)
  "Render Markdown TEXT into a propertized string.
Each block of the result -- a paragraph, a heading, a list item, a code
block, a table, the lines of a quote -- has the text property
`harness-md-source', (FROM . TO): where in TEXT the block was written,
as offsets of characters.  Something that acts on what is on the screen
-- a reply to part of it -- knows from that what the text it selects was
rendered from."
  (let* ((text (or text ""))
         (lines (split-string text "\n"))
         (all (vconcat lines))
         (total (length all))
         (starts (let ((pos 0) (acc nil))
                   (dolist (line lines)
                     (push pos acc)
                     (setq pos (+ pos (length line) 1)))
                   (vconcat (nreverse acc))))
         (out nil)
         (para nil)
         (para-first nil)
         (para-last nil))
    (cl-labels
        ((here () (- total (length lines) 1))
         (mark (string first last)
           ;; STRING came from lines FIRST to LAST: say where in TEXT.
           (when (and (stringp string) (> (length string) 0) (<= first last))
             (put-text-property 0 (length string) 'harness-md-source
                                (cons (aref starts first) (+ (aref starts last) (length (aref all last))))
                                string))
           string)
         (flush-para ()
           ;; Every block branch calls this between matching its line and
           ;; reading the groups, so the inline rendering must leave the
           ;; match data alone.
           (when para
             (save-match-data
               (push (mark (concat (harness-ui-markdown-inline
                                    (string-join (nreverse para) (if harness-ui-markdown-hard-breaks "\n" " ")))
                                   "\n")
                           para-first para-last)
                     out))
             (setq para nil)))
         (emit (s) (push s out)))
      (while lines
        (let* ((line (pop lines))
               (first (here)))
          (cond
           ;; Fenced code block
           ((string-match "\\`[ ]\\{0,3\\}\\(```+\\|~~~+\\)[ ]*\\([A-Za-z0-9_+.-]*\\)" line)
            (flush-para)
            (let ((fence (match-string 1 line)) (lang (match-string 2 line)) (code nil))
              (while (and lines (not (string-match-p (concat "\\`[ ]\\{0,3\\}" (regexp-quote fence) "[ ]*\\'") (car lines))))
                (push (pop lines) code))
              (pop lines)
              (emit (mark (harness-ui-markdown--code-block (string-join (nreverse code) "\n") lang)
                          first (min (here) (1- total))))))
           ;; Heading
           ((string-match "\\`\\(#\\{1,6\\}\\)[ \t]+\\(.*?\\)[ \t#]*\\'" line)
            (flush-para)
            (let* ((level (length (match-string 1 line)))
                   (face (pcase level (1 'harness-md-heading-1) (2 'harness-md-heading-2)
                                (3 'harness-md-heading-3) (_ 'harness-md-heading-4))))
              (emit (mark (concat (harness-ui-markdown--add-face (harness-ui-markdown-inline (match-string 2 line)) face) "\n")
                          first first))))
           ;; Horizontal rule
           ((harness-ui-markdown--rule-p line)
            (flush-para)
            (emit (mark (propertize (concat (make-string 40 ?\s) "\n") 'face 'harness-md-rule) first first)))
           ;; Table (a line with pipes followed by a separator line)
           ((and (string-match-p "|" line) lines
                 (string-match-p "\\`[ ]*|?[ ]*:?-+:?[ ]*\\(|[ ]*:?-+:?[ ]*\\)*|?[ ]*\\'" (car lines)))
            (flush-para)
            (let ((rows (list line)))
              (while (and lines (string-match-p "|" (car lines)))
                (push (pop lines) rows))
              (emit (mark (harness-ui-markdown--table (nreverse rows)) first (here)))))
           ;; Block quote
           ((string-match "\\`[ ]\\{0,3\\}>[ ]?\\(.*\\)\\'" line)
            (flush-para)
            (let ((quoted (list (match-string 1 line))))
              (while (and lines (string-match "\\`[ ]\\{0,3\\}>[ ]?\\(.*\\)\\'" (car lines)))
                (push (match-string 1 (pop lines)) quoted))
              (let ((inner (harness-ui-markdown-render (string-join (nreverse quoted) "\n")))
                    (last (here)))
                (dolist (l (split-string (string-trim-right inner "\n") "\n"))
                  (emit (mark (concat (propertize "┃ " 'face 'harness-md-quote-bar)
                                      (harness-ui-markdown--add-face l 'harness-md-quote) "\n")
                              first last))))))
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
              (emit (mark (harness-ui-markdown--wrap
                           (concat (harness-ui-markdown-inline (string-join (nreverse body) " ")) "\n")
                           prefix
                           (concat (make-string indent ?\s) (propertize bullet 'face 'harness-md-bullet)))
                          first (here)))))
           ;; Blank line
           ((string-blank-p line)
            (flush-para)
            (when (and out (not (string-suffix-p "\n\n" (car out))))
              (emit "\n")))
           ;; Paragraph text
           (t (unless para (setq para-first first))
              (setq para-last first)
              (push line para)))))
      (flush-para))
    (let ((s (apply #'concat (nreverse out))))
      (string-trim-right s "\n+"))))

(defun harness-ui-markdown-insert (text)
  "Insert Markdown TEXT rendered at point."
  (insert (harness-ui-markdown-render text)))

;;;; In lines

;; `harness-ui-markdown-render' leaves the wrapping to the window: the
;; hanging indent of a list item and the margin of a code block are
;; `wrap-prefix' and `line-prefix' properties, which the display engine
;; reads where a screen line starts.  A caller that draws a line at a
;; time -- a bar down the side of a comment, a thread under a line of
;; code, in an overlay -- starts every line with text of its own, so
;; those properties do nothing there, and a line longer than the room
;; wraps to the margin, away from its bar.  `harness-ui-markdown-render-lines'
;; wraps the lines and indents them in the text instead.

(defun harness-ui-markdown--break (string start room hard)
  "Cut a piece of ROOM columns at most off STRING, from START.
Return (END . NEXT): the piece is from START to END, and the next one
starts at NEXT, which is nil when the piece is the end of STRING.  The
cut is at the last space the piece can end at, and the blanks it leaves
are dropped, unless HARD: then it is where ROOM ends, blanks and all,
as code and tables need.  A word wider than ROOM is cut inside."
  (let* ((length (length string))
         (width 0)
         (i start))
    (while (and (< i length) (<= (+ width (char-width (aref string i))) room))
      (cl-incf width (char-width (aref string i)))
      (cl-incf i))
    (if (>= i length)
        (cons length nil)
      (if hard
          (let ((cut (max i (1+ start))))
            (cons cut (and (< cut length) cut)))
        ;; The first character that is no blank: a cut before it would
        ;; leave an empty piece.
        (let* ((lead (let ((p start))
                       (while (and (< p length) (memq (aref string p) '(?\s ?\t)))
                         (cl-incf p))
                       p))
               (space (if (and (eq (aref string i) ?\s) (> i lead))
                          i
                        (cl-position ?\s string :start (min lead i) :end i :from-end t)))
               (cut (if (and space (> space lead)) space (max i (1+ start))))
               (end cut)
               (next cut))
          (while (and (> end start) (memq (aref string (1- end)) '(?\s ?\t)))
            (cl-decf end))
          (while (and (< next length) (memq (aref string next) '(?\s ?\t)))
            (cl-incf next))
          (cons end (and (< next length) next)))))))

(defun harness-ui-markdown--wrap-line (line first rest width hard)
  "Return LINE, rendered text, as the lines it takes in WIDTH columns.
FIRST goes before the first line, REST before the others.  HARD says
to cut where the room ends rather than at a space, see
`harness-ui-markdown--break'.  Neither prefix takes more than half
the width, and a line is given eight columns at least."
  (let* ((first-room (max 8 (- width (min (string-width first) (/ width 2)))))
         (rest-room (max 8 (- width (min (string-width rest) (/ width 2)))))
         (prefix first)
         (room first-room)
         (start 0)
         (pieces nil))
    (while start
      (pcase-let ((`(,end . ,next) (harness-ui-markdown--break line start room hard)))
        (push (concat prefix (substring line start end)) pieces)
        (setq start next prefix rest room rest-room)))
    (nreverse pieces)))

(defun harness-ui-markdown--string-face-p (string pos face)
  "Non-nil when the text of STRING at POS is drawn in FACE, alone or among others."
  (let ((faces (get-text-property pos 'face string)))
    (if (consp faces) (memq face faces) (eq faces face))))

(defun harness-ui-markdown-code-at-p (string pos)
  "Return non-nil when the character of STRING at POS was rendered as code.
STRING is rendered Markdown (`harness-ui-markdown-render'); code is what
the renderer drew in a fenced block or between backquotes.  What it says
is meant literally: whoever finds things in rendered text, to link them,
leaves it alone."
  (or (eq (get-text-property pos 'harness-md-block string) 'code)
      (and (harness-ui-markdown--string-face-p string pos 'harness-md-code) t)))

(defun harness-ui-markdown-render-lines (text width)
  "Render Markdown TEXT as a list of lines, each WIDTH columns at most.
Each line is a string that ends in a newline, with the faces and
properties `harness-ui-markdown-render' gives it, for a caller that
draws a line at a time, after a margin of its own.  What the renderer
leaves to the window is in the text instead: the hanging indent of a
list item, the margin of a code block, the bar a block quote's lines
start with, so a line that does not fit is cut into lines that start
where the window would have started them.  Code and table lines are cut
where the room ends, not at a space, and a table is fitted to WIDTH by
`harness-ui-markdown-table-width'.  A newline a code block gave its
line keeps its face, whose background reaches the edge of the window.
Empty TEXT is one empty line.  WIDTH is eight columns at least: what is
narrower gets eight.

`harness-ui-markdown-hard-breaks' says whether the lines of a paragraph
join, as in `harness-ui-markdown-render'."
  (let* ((harness-ui-markdown-table-width width)
         (rendered (harness-ui-markdown-render text))
         (end (length rendered))
         (pos 0)
         (lines nil))
    (while (<= pos end)
      (let* ((eol (or (string-search "\n" rendered pos) end))
             (line (substring rendered pos eol))
             (block (get-text-property pos 'harness-md-block rendered))
             (code (eq block 'code))
             (first (let ((prefix (get-text-property pos 'line-prefix rendered)))
                      (if (stringp prefix) prefix "")))
             (hanging (get-text-property pos 'wrap-prefix rendered))
             ;; The bars a block quote starts its lines with.
             (bar-end (let ((p pos))
                        (while (and (< p eol)
                                    (harness-ui-markdown--string-face-p rendered p 'harness-md-quote-bar))
                          (cl-incf p))
                        p))
             (rest (cond (code first)
                         ((stringp hanging) hanging)
                         ((> bar-end pos) (substring rendered pos bar-end))
                         (t "")))
             ;; The renderer trims the newlines it ends with.
             (newline (cond ((< eol end) (substring rendered eol (1+ eol)))
                            (code (propertize "\n" 'face 'harness-md-code-block))
                            (t "\n")))
             (pieces (if (string-blank-p line)
                         ;; A rule, or an empty line: no margin on it.
                         (list (truncate-string-to-width line width))
                       (harness-ui-markdown--wrap-line
                        line first rest width (memq block '(code table))))))
        (dolist (piece pieces)
          (let ((string (concat piece newline)))
            ;; The margins are text now: left as properties they would
            ;; be drawn a second time.
            (remove-text-properties 0 (length string) '(line-prefix nil wrap-prefix nil) string)
            (push string lines)))
        (setq pos (1+ eol))))
    (nreverse lines)))

(defconst harness-ui-markdown--summary-limit 1000
  "How much of a text `harness-ui-markdown-summary' reads: the start of it.")

(defun harness-ui-markdown--summary-face (faces)
  "Return FACES, a `face' property, as a line of a list wants it.
A heading's face is plain bold: its height would make the line taller
than the rest.  A link's face goes: in a summary a link is its label."
  (let ((faces (if (and (consp faces) (not (keywordp (car faces)))) faces (list faces))))
    (delete-dups
     (delq 'link
           (mapcar (lambda (face)
                     (if (memq face '(harness-md-heading-1 harness-md-heading-2
                                      harness-md-heading-3 harness-md-heading-4))
                         'bold
                       face))
                   faces)))))

(defun harness-ui-markdown-summary (text)
  "Return Markdown TEXT as one line, for a list that names items by it.
The text is rendered, so the line has no markers of the markup in it,
only its faces, a heading's among them as plain bold; a link is its
label, which does nothing; the language a code block names is left out,
and line breaks and runs of blanks become a space each.  Only the start
of a long text is read: the first words are what a caller cuts the line
to."
  (let* ((rendered (harness-ui-markdown-render
                    (let ((text (or text "")))
                      (if (> (length text) harness-ui-markdown--summary-limit)
                          (substring text 0 harness-ui-markdown--summary-limit)
                        text))))
         (parts nil)
         (pos 0))
    (while (< pos (length rendered))
      (let ((next (next-single-property-change pos 'face rendered (length rendered)))
            (faces (get-text-property pos 'face rendered)))
        (unless (harness-ui-markdown--string-face-p rendered pos 'harness-md-code-lang)
          (push (if faces
                    (let ((part (substring rendered pos next)))
                      (put-text-property 0 (length part) 'face
                                         (harness-ui-markdown--summary-face faces) part)
                      part)
                  (substring rendered pos next))
                parts))
        (setq pos next)))
    (let ((line (string-trim (replace-regexp-in-string "[ \t\n]+" " " (apply #'concat (nreverse parts))))))
      (remove-text-properties
       0 (length line) '(harness-url nil keymap nil follow-link nil mouse-face nil help-echo nil) line)
      line)))

;;;; Reading rendered text back

;; Quoting part of a rendered message takes the text as it shows, which
;; has lost its Markdown.  What the renderer drew of its own -- the
;; fences and language of a code block, the backquotes of inline code, a
;; link's target, bullets, quote bars -- its text properties still tell,
;; and `harness-ui-markdown-source' puts back.

(defun harness-ui-markdown--face-p (pos face)
  "Non-nil when the text at POS is drawn in FACE, alone or among others."
  (let ((faces (get-text-property pos 'face)))
    (if (consp faces) (memq face faces) (eq faces face))))

(defun harness-ui-markdown--quoted-line-p (pos)
  "Non-nil when POS is on a line of a rendered block quote."
  (save-excursion
    (goto-char pos)
    (harness-ui-markdown--face-p (line-beginning-position) 'harness-md-quote-bar)))

(defun harness-ui-markdown--code-lang (pos)
  "Return the language of the rendered code block POS is in, or \"\".
That is its label line: the nearest one at or above POS among the
block's lines."
  (save-excursion
    (goto-char pos)
    (forward-line 0)
    (catch 'found
      (while (eq (get-text-property (point) 'harness-md-block) 'code)
        (when (harness-ui-markdown--face-p (point) 'harness-md-code-lang)
          (throw 'found (string-trim (buffer-substring-no-properties (point) (line-end-position)))))
        (when (bobp) (throw 'found ""))
        (forward-line -1))
      "")))

(defun harness-ui-markdown--piece-kind (pos)
  "Return what the rendered text at POS was made from, to read it back.
One of `hidden' (it does not show), `label' (a code block's language),
`code' (a code block's text), `inline' (inline code), (link . URL),
`bullet', `bar' (a block quote's) or `text', anything else.  A code
block inside a quote reads as text: its fences would have to go inside
the quote."
  (let ((url (get-text-property pos 'harness-url)))
    (cond ((invisible-p pos) 'hidden)
          ((and (eq (get-text-property pos 'harness-md-block) 'code)
                (not (harness-ui-markdown--quoted-line-p pos)))
           (if (harness-ui-markdown--face-p pos 'harness-md-code-lang) 'label 'code))
          ((harness-ui-markdown--face-p pos 'harness-md-code) 'inline)
          (url (cons 'link url))
          ((harness-ui-markdown--face-p pos 'harness-md-bullet) 'bullet)
          ((harness-ui-markdown--face-p pos 'harness-md-quote-bar) 'bar)
          (t 'text))))

(defun harness-ui-markdown--pieces (beg end)
  "Return the text from BEG to END as (KIND START . END) pieces, in order.
KIND is what `harness-ui-markdown--piece-kind' says of the piece; text
next to each other of the same kind is one piece."
  (let ((pos beg) (pieces nil))
    (while (< pos end)
      (let ((next (min (next-single-char-property-change pos 'invisible nil end)
                       (next-single-property-change pos 'face nil end)
                       (next-single-property-change pos 'harness-md-block nil end)
                       (next-single-property-change pos 'harness-url nil end)))
            (kind (harness-ui-markdown--piece-kind pos)))
        (if (and pieces (equal kind (car (car pieces))))
            (setcdr (cdr (car pieces)) next)
          (push (cons kind (cons pos next)) pieces))
        (setq pos next)))
    (nreverse pieces)))

(defun harness-ui-markdown-source (beg end)
  "Return Markdown for the rendered text from BEG to END in this buffer.
The text is read back as far as its properties tell what the renderer
made it from: a code block goes back between fences, under its
language, inline code between backquotes, a link whose label is not its
target to [label](target), a bullet to \"-\", a quote bar to \">\".
Emphasis and headings, which are faces alone, read as plain text, and
so does text the renderer did not make.  Text that does not show,
hidden in a folded block say, is left out."
  (let ((parts nil) (fenced nil))
    (cl-labels ((emit (string) (unless (string-empty-p string) (push string parts)))
                (fresh-line () (when (and parts (not (string-suffix-p "\n" (car parts)))) (emit "\n")))
                (open-fence (pos) (fresh-line) (emit (concat "```" (harness-ui-markdown--code-lang pos) "\n"))
                            (setq fenced t))
                (close-fence () (when fenced (fresh-line) (emit "```\n") (setq fenced nil))))
      (pcase-dolist (`(,kind ,from . ,to) (harness-ui-markdown--pieces beg end))
        (let ((text (buffer-substring-no-properties from to)))
          (pcase kind
            ('hidden nil)
            ;; The label is the fence's language, not a line of code.
            ('label (close-fence) (open-fence from))
            ('code (unless fenced (open-fence from)) (emit text))
            (_ (close-fence)
               (emit (pcase kind
                       ('inline (concat "`" text "`"))
                       (`(link . ,url) (if (equal text url) text (format "[%s](%s)" text url)))
                       ('bullet (string-replace "•" "-" text))
                       ('bar (string-replace "┃" ">" text))
                       (_ text)))))))
      (close-fence))
    (apply #'concat (nreverse parts))))

(provide 'harness-ui-markdown)
;;; harness-ui-markdown.el ends here
