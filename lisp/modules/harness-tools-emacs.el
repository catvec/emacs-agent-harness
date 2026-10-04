;;; harness-tools-emacs.el --- Tools that look inside the user's Emacs  -*- lexical-binding: t; -*-

;;; Commentary:

;; Narrow windows into the user's Emacs so a model can help drive it:
;; the buffer and window lists, a buffer's text, showing a buffer or a
;; file where the user can see it, inserting text into a buffer, saving
;; one, documentation and values of symbols, and the tail of *Messages*.
;; None of them evaluates code: model-written Lisp never runs in the
;; user's Emacs, and the elisp tool (tools-shell) evaluates in a
;; background Emacs instead.
;;
;; Like every tool these run here, in the harness.  The user's Emacs is
;; a resource they reach, as a TRAMP host is for the file tools: they
;; check their input, ask the Emacs a client lent to the harness for
;; plain data or one bounded action (`harness-tools-ask-emacs';
;; lisp/harness-emacs-endpoint.el answers in that Emacs) and word the
;; result here.  A client that lends no Emacs, such as a phone, is
;; never asked; with none attached (a headless harness) these tools say
;; so, and every other tool works.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(defconst harness-tools-emacs--value-chars 500
  "Variable values longer than this are truncated by emacs_describe.")

(defconst harness-tools-emacs--messages-default 50
  "Number of *Messages* lines emacs_messages returns by default.")

(defconst harness-tools-emacs--no-emacs-hint
  "Read files with read_file, or evaluate Lisp in a background Emacs with the elisp tool."
  "What the model is told to do instead when the user's Emacs cannot be asked.")

(defun harness-tools-emacs--buffer-chars ()
  "Return the most characters of text emacs_buffer reads in one call.
Two thirds of `harness-tools-max-output-chars', which leaves room for the
line numbers, so a long buffer comes in ranges instead of crossing from
the user's Emacs whole."
  (max 1000 (/ (* 2 harness-tools-max-output-chars) 3)))

(defconst harness-tools-emacs--open-max-bytes (* 8 1024 1024)
  "Largest file emacs_open has the user's Emacs visit.
Reading a file into that Emacs happens on its only thread, so a larger
file is refused with a message to read it in ranges instead.")

(defconst harness-tools-emacs--insert-max-chars (* 10 1024 1024)
  "Longest text emacs_insert accepts.
Insertion copies the text on the user's Emacs's only thread, so a
larger text is refused rather than freeze it moving the text.")

(defconst harness-tools-emacs--write-hint
  "Write the change to a file with write_file or edit_file instead."
  "What the model is told when a write to the user's Emacs is refused.")

(defun harness-tools-emacs--ask (method params format-answer &optional hint)
  "Ask the user's Emacs for METHOD with PARAMS; return a promise of a tool result.
FORMAT-ANSWER turns the answer into the result.  When the Emacs cannot
be asked or does not answer, the result is an error that says why,
followed by HINT: `harness-tools-emacs--no-emacs-hint' by default,
`:none' for no hint at all."
  (harness-then
   (harness-tools-ask-emacs method params)
   (lambda (answer)
     (condition-case err
         (funcall format-answer answer)
       (error (harness-tool-error (harness-error-message err)))))
   (lambda (err)
     (let ((text (harness-tools-sentence (harness-tools-reason err))))
       (harness-tool-error
        (pcase hint
          ('nil (concat text " " harness-tools-emacs--no-emacs-hint))
          (':none text)
          (_ (concat text " " hint))))))))

(defun harness-tools-emacs--int (value default)
  "Return VALUE as an integer, or DEFAULT."
  (cond ((integerp value) value)
        ((numberp value) (truncate value))
        ((and (stringp value) (string-match-p "\\`-?[0-9]+\\'" value)) (string-to-number value))
        (t default)))

;;;; emacs_buffers

(defun harness-tools-emacs--buffer-row (buffer)
  "Return the row of emacs_buffers for BUFFER, a plist the user's Emacs sent."
  (let ((file (plist-get buffer :file)))
    (list (or (plist-get buffer :name) "")
          (or (plist-get buffer :mode) "")
          (if (harness-json-true-p (plist-get buffer :modified)) "*" "")
          (harness-format-bytes (plist-get buffer :size))
          (if (stringp file) (abbreviate-file-name file) ""))))

(defun harness-tools-emacs--format-buffers (buffers filter all)
  "Return the emacs_buffers result for BUFFERS, matched against FILTER.
Hidden buffers, whose names start with a space, are left out unless ALL."
  (let* ((filter (and (stringp filter) (not (string-empty-p filter)) filter))
         (rows (mapcar #'harness-tools-emacs--buffer-row
                       (cl-remove-if-not
                        (lambda (b)
                          (let ((name (or (plist-get b :name) ""))
                                (file (plist-get b :file)))
                            (and (or all (not (string-prefix-p " " name)))
                                 (or (not filter)
                                     (string-match-p filter name)
                                     (and (stringp file) (string-match-p filter file))))))
                        buffers))))
    (if (null rows)
        (harness-tool-ok "No buffers match")
      (let ((w1 (min 40 (apply #'max (mapcar (lambda (r) (length (car r))) rows))))
            (w2 (min 28 (apply #'max (mapcar (lambda (r) (length (cadr r))) rows)))))
        (harness-tool-ok
         (concat (format (format "%%-%ds  %%-%ds  M  %%8s  %%s\n" w1 w2) "NAME" "MODE" "SIZE" "FILE")
                 (mapconcat (lambda (r)
                              (format (format "%%-%ds  %%-%ds  %%1s  %%8s  %%s" w1 w2)
                                      (harness-truncate-end (nth 0 r) w1) (harness-truncate-end (nth 1 r) w2)
                                      (nth 2 r) (nth 3 r) (nth 4 r)))
                            rows "\n")
                 (format "\n(%d buffer%s)" (length rows) (if (= 1 (length rows)) "" "s"))))))))

(defun harness-tools-emacs--buffers (input _ctx)
  "Handler for emacs_buffers with INPUT."
  (let ((filter (plist-get input :filter))
        (all (harness-json-true-p (plist-get input :all))))
    (harness-tools-emacs--ask
     "buffers" :empty
     (lambda (answer) (harness-tools-emacs--format-buffers (plist-get answer :buffers) filter all)))))

(harness-define-tool "emacs_buffers"
  :label "List buffers"
  :description "List the live buffers in the user's Emacs: name, major mode, modified flag (M), size and visited file."
  :schema '(:type "object"
            :properties (:filter (:type "string" :description "Only buffers whose name or file matches this regexp")
                         :all (:type "boolean" :description "Include hidden buffers (names starting with a space). Default false")))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (when-let* ((filter (plist-get input :filter))) (format "/%s/" filter)))
  :handler #'harness-tools-emacs--buffers)

;;;; emacs_windows

(defun harness-tools-emacs--format-windows (windows)
  "Return the emacs_windows result for WINDOWS, the rows the Emacs sent."
  (let ((rows (mapcar (lambda (window)
                        (let ((file (plist-get window :file)))
                          (list (format "%s" (or (plist-get window :frame) 1))
                                (if (harness-json-true-p (plist-get window :selected)) "*" "")
                                (or (plist-get window :name) "")
                                (or (plist-get window :mode) "")
                                (format "%sx%s" (or (plist-get window :width) 0)
                                        (or (plist-get window :height) 0))
                                (if (stringp file) (abbreviate-file-name file) ""))))
                      windows)))
    (if (null rows)
        (harness-tool-ok "No windows")
      (let ((w1 (min 5 (apply #'max (mapcar (lambda (r) (length (nth 0 r))) rows))))
            (w2 (min 40 (apply #'max (mapcar (lambda (r) (length (nth 2 r))) rows))))
            (w3 (min 28 (apply #'max (mapcar (lambda (r) (length (nth 3 r))) rows))))
            (w4 (min 11 (apply #'max (mapcar (lambda (r) (length (nth 4 r))) rows)))))
        (harness-tool-ok
         (concat (format (format "%%-%ds  SEL  %%-%ds  %%-%ds  %%-%ds  %%s\n" w1 w2 w3 w4)
                         "FRAME" "BUFFER" "MODE" "SIZE" "FILE")
                 (mapconcat (lambda (r)
                              (format (format "%%-%ds  %%1s    %%-%ds  %%-%ds  %%-%ds  %%s" w1 w2 w3 w4)
                                      (nth 0 r) (nth 1 r)
                                      (harness-truncate-end (nth 2 r) w2)
                                      (harness-truncate-end (nth 3 r) w3)
                                      (nth 4 r) (nth 5 r)))
                            rows "\n")
                 (format "\n(%d window%s)"
                         (length rows) (if (= 1 (length rows)) "" "s"))))))))

(defun harness-tools-emacs--windows (_input _ctx)
  "Handler for emacs_windows."
  (harness-tools-emacs--ask
   "windows" :empty
   (lambda (answer) (harness-tools-emacs--format-windows (plist-get answer :windows)))))

(harness-define-tool "emacs_windows"
  :label "List windows"
  :description "List the windows of the user's Emacs, frame by frame: which window is selected, the buffer it shows, its mode, its size in characters and the buffer's file. Read-only."
  :schema '(:type "object" :properties :empty)
  :kind 'read
  :coalescable t
  :subject #'ignore
  :handler #'harness-tools-emacs--windows)

;;;; emacs_buffer

(defun harness-tools-emacs--format-buffer (name answer)
  "Return the emacs_buffer result for buffer NAME from ANSWER.
ANSWER is what the user's Emacs sent: the lines, and where they are."
  (let* ((total (or (plist-get answer :total) 0))
         (first (or (plist-get answer :first) 1))
         (lines (plist-get answer :lines))
         (last (+ first (length lines) -1))
         (mode (plist-get answer :mode))
         (file (plist-get answer :file)))
    (cond
     ((not (harness-json-true-p (plist-get answer :exists)))
      (harness-tool-error (format "No buffer named %S; use emacs_buffers to list them" name)))
     ((zerop total) (harness-tool-ok (format "Buffer %s is empty" name)))
     ((> first total)
      (harness-tool-error (format "offset %d is past the end of %s (%d lines)" first name total)))
     (t
      (harness-tool-ok
       (format "%s\n\n[%s (%s): lines %d-%d of %d%s%s%s]"
               (string-join (cl-loop for line in lines for n from first
                                     collect (format "%6d\t%s" n line))
                            "\n")
               name mode first last total
               (if (stringp file) (format ", file %s" (abbreviate-file-name file)) "")
               (if (harness-json-true-p (plist-get answer :modified)) ", modified" "")
               (if (harness-json-true-p (plist-get answer :truncated))
                   (format "; stopped at %d characters, read on with offset %d"
                           (harness-tools-emacs--buffer-chars) (1+ last))
                 "")))))))

(defun harness-tools-emacs--buffer (input _ctx)
  "Handler for emacs_buffer with INPUT."
  (let ((name (plist-get input :name))
        (offset (max 1 (harness-tools-emacs--int (plist-get input :offset) 1)))
        (limit (harness-tools-emacs--int (plist-get input :limit) nil)))
    (if (not (stringp name))
        (harness-tool-error "Missing name")
      (harness-tools-emacs--ask
       "buffer" (list :name name :offset offset :limit (and limit (max 0 limit))
                      :maxChars (harness-tools-emacs--buffer-chars))
       (lambda (answer) (harness-tools-emacs--format-buffer name answer))))))

(harness-define-tool "emacs_buffer"
  :label "Read buffer"
  :description "Read the text of a live buffer with line numbers, optionally a range (offset is the 1-based first line, limit the number of lines)."
  :schema '(:type "object"
            :properties (:name (:type "string" :description "Buffer name, exactly as emacs_buffers lists it")
                         :offset (:type "integer" :description "First line to return (1-based). Default 1")
                         :limit (:type "integer" :description "Maximum number of lines. Default: all"))
            :required ("name"))
  :kind 'read
  :coalescable t
  :subject (lambda (input)
             (when-let* ((name (plist-get input :name)))
               (let ((o (plist-get input :offset)) (l (plist-get input :limit)))
                 (format "%s%s" name
                         (cond ((and o l) (format ":%s-%s" o (+ o l -1))) (o (format ":%s-" o)) (t ""))))))
  :handler #'harness-tools-emacs--buffer)

;;;; emacs_open

(defun harness-tools-emacs--format-open (answer line)
  "Return the emacs_open result for ANSWER, the Emacs's report.
LINE is the line the call asked for, when it did."
  (let* ((name (or (plist-get answer :name) ""))
         (mode (or (plist-get answer :mode) ""))
         (file (plist-get answer :file))
         (where (if (harness-json-true-p (plist-get answer :visited)) "Visited" "Showed")))
    (harness-tool-ok
     (format "%s %s (%s, %s%s)%s in the selected window%s"
             where name mode (harness-format-bytes (plist-get answer :size))
             (if (harness-json-true-p (plist-get answer :modified)) ", modified" "")
             (if (and (stringp file) (not (equal (file-name-nondirectory file) name)))
                 (format ", file %s" (abbreviate-file-name file))
               "")
             (if (and line (> line 0)) (format " at line %d" line) "")))))

(defun harness-tools-emacs--open (input ctx)
  "Handler for emacs_open with INPUT under CTX.
The file path the name resolves to is worked out here, in the session's
working directory, and the tool declares it as its path so the
permission jail judges it like any other read; the Emacs named by the
lent client then shows a buffer of that name if one is live, or visits
the file."
  (let ((name (plist-get input :name))
        (line (harness-tools-emacs--int (plist-get input :line) nil)))
    (if (not (stringp name))
        (harness-tool-error "Missing name")
      (harness-tools-emacs--ask
       "open"
       (list :name name
             :path (harness-tools-resolve-path name ctx)
             :line (and line (> line 0) line)
             :maxBytes harness-tools-emacs--open-max-bytes)
       (lambda (answer) (harness-tools-emacs--format-open answer line))))))

(harness-define-tool "emacs_open"
  :label "Open buffer"
  :description "Show a buffer or a file in the user's Emacs, where they can see it, optionally with point at a line. NAME is a live buffer (as emacs_buffers lists it) or a file path; a file is visited first when no buffer has it. Only existing, local, regular files under 8 MiB are opened; directories, remote (TRAMP) files and larger files are refused instead of risking a freeze. Does not change any file, and never prompts."
  :schema '(:type "object"
            :properties (:name (:type "string" :description "Buffer name (as emacs_buffers lists it) or file path")
                         :line (:type "integer" :description "Line to put point at, 1-based. Optional"))
            :required ("name"))
  :kind 'read
  :paths (lambda (input) (list (plist-get input :name)))
  :coalescable t
  :subject (lambda (input) (when-let* ((name (plist-get input :name))) name))
  :handler #'harness-tools-emacs--open)

;;;; emacs_insert

(defun harness-tools-emacs--position (value)
  "Return the insert position VALUE names: \"point\", \"start\" or \"end\".
Return nil when VALUE names none of them."
  (let ((name (and value (downcase (format "%s" value)))))
    (cond ((or (null value) (string-empty-p name) (equal name "point")) "point")
          ((equal name "start") "start")
          ((equal name "end") "end"))))

(defun harness-tools-emacs--insert (input _ctx)
  "Handler for emacs_insert with INPUT."
  (let* ((name (plist-get input :name))
         (text (plist-get input :text))
         (position (harness-tools-emacs--position (plist-get input :position)))
         (raw-position (plist-get input :position)))
    (cond
     ((not (stringp name)) (harness-tool-error "Missing name"))
     ((not (stringp text)) (harness-tool-error "Missing text"))
     ((and raw-position (not position))
      (harness-tool-error (format "position must be point, start or end, not %S" raw-position)))
     ((> (length text) harness-tools-emacs--insert-max-chars)
      (harness-tool-error
       (format "Text is %d characters, over the %d the emacs_insert limit allows"
               (length text) harness-tools-emacs--insert-max-chars)))
     (t
      (harness-tools-emacs--ask
       "insert"
       (list :name name :text text :position position
             :maxChars harness-tools-emacs--insert-max-chars)
       (lambda (answer)
         (harness-tool-ok
          (format "Inserted %s characters %s in %s (from line %s); not saved"
                  (or (plist-get answer :inserted) (length text))
                  (pcase position ("point" "at point") ("start" "at the start") (_ "at the end"))
                  (or (plist-get answer :name) name)
                  (or (plist-get answer :line) 1))))
       harness-tools-emacs--write-hint)))))

(harness-define-tool "emacs_insert"
  :label "Insert text"
  :description "Insert text into a live buffer in the user's Emacs, at point (default), at the start or at the end; the buffer is left modified, not saved (use emacs_save_buffer for that). Refuses read-only buffers and the harness's own UI buffers. This is text editing, not evaluation; it cannot change modes, run commands or reach outside the buffer."
  :schema '(:type "object"
            :properties (:name (:type "string" :description "Buffer name, exactly as emacs_buffers lists it")
                         :text (:type "string" :description "The text to insert")
                         :position (:type "string" :enum ("point" "start" "end")
                                    :description "Where to insert: at point (default), the start or the end of the buffer"))
            :required ("name" "text"))
  :kind 'write
  :subject (lambda (input) (plist-get input :name))
  :handler #'harness-tools-emacs--insert)

;;;; emacs_save_buffer

(defun harness-tools-emacs--save-buffer (input _ctx)
  "Handler for emacs_save_buffer with INPUT."
  (let ((name (plist-get input :name)))
    (if (not (stringp name))
        (harness-tool-error "Missing name")
      (harness-tools-emacs--ask
       "save" (list :name name)
       (lambda (answer)
         (harness-tool-ok
          (format "Saved %s to %s"
                  (or (plist-get answer :name) name)
                  (abbreviate-file-name (or (plist-get answer :path) "")))))
       harness-tools-emacs--write-hint))))

(harness-define-tool "emacs_save_buffer"
  :label "Save buffer"
  :description "Save a live buffer to the local file it visits, as the user would with `save-buffer'. Refuses buffers with no file, remote (TRAMP) files, and files that changed on disk since the buffer was read; it never waits on a lock file or a prompt."
  :schema '(:type "object"
            :properties (:name (:type "string" :description "Buffer name, exactly as emacs_buffers lists it"))
            :required ("name"))
  :kind 'write
  :subject (lambda (input) (plist-get input :name))
  :handler #'harness-tools-emacs--save-buffer)

;;;; emacs_describe

(defun harness-tools-emacs--format-describe (name answer)
  "Return the emacs_describe result for the symbol NAME from ANSWER."
  (if (not (harness-json-true-p (plist-get answer :known)))
      (harness-tool-error (format "No symbol named %s is known to the user's Emacs" name))
    (let* ((doc (lambda (part)
                  (let ((d (plist-get part :doc)))
                    (if (and (stringp d) (not (string-empty-p d))) d "(no documentation)"))))
           (fn (plist-get answer :function))
           (var (plist-get answer :variable))
           (face (plist-get answer :face))
           (parts (delq nil
                        (list (and fn (format "%s: %s\n%s" (plist-get fn :kind) (plist-get fn :signature)
                                              (funcall doc fn)))
                              (and var (format "%s: %s\nvalue: %s\n%s" (plist-get var :kind) (string-trim name)
                                               (plist-get var :value) (funcall doc var)))
                              (and face (format "face: %s\n%s" (string-trim name)
                                                (or (plist-get face :doc) "")))))))
      (if parts
          (harness-tool-ok (string-join parts "\n\n"))
        (harness-tool-error (format "%s is neither a function nor a variable" (string-trim name)))))))

(defun harness-tools-emacs--describe (input _ctx)
  "Handler for emacs_describe with INPUT."
  (let ((name (plist-get input :symbol)))
    (if (not (stringp name))
        (harness-tool-error "Missing symbol")
      (harness-tools-emacs--ask
       "describe" (list :symbol name :maxValueChars harness-tools-emacs--value-chars)
       (lambda (answer) (harness-tools-emacs--format-describe name answer))))))

(harness-define-tool "emacs_describe"
  :label "Describe symbol"
  :description "Describe an Emacs symbol: function signature and docstring, variable docstring and current value (truncated)."
  :schema '(:type "object"
            :properties (:symbol (:type "string" :description "The symbol name, e.g. find-file or fill-column"))
            :required ("symbol"))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (plist-get input :symbol))
  :handler #'harness-tools-emacs--describe)

;;;; emacs_messages

(defun harness-tools-emacs--messages (input _ctx)
  "Handler for emacs_messages with INPUT."
  (let ((count (max 1 (harness-tools-emacs--int (plist-get input :count)
                                                harness-tools-emacs--messages-default))))
    (harness-tools-emacs--ask
     "messages" (list :count count)
     (lambda (answer)
       (let ((text (plist-get answer :text)))
         (harness-tool-ok (if (or (not (stringp text)) (string-empty-p text)) "*Messages* is empty" text)))))))

(harness-define-tool "emacs_messages"
  :label "Emacs messages"
  :description "Return the last lines of the *Messages* buffer (errors, warnings and messages Emacs showed the user)."
  :schema '(:type "object"
            :properties (:count (:type "integer" :description "Number of lines. Default 50")))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (format "last %s lines" (or (plist-get input :count) harness-tools-emacs--messages-default)))
  :handler #'harness-tools-emacs--messages)

(harness-define-module 'tools-emacs
  :doc "List buffers, List windows, Read buffer, Open buffer, Insert text, Save buffer, Describe symbol and Emacs messages: bounded tools into the user's Emacs, without evaluation."
  :requires '(tools))

(provide 'harness-tools-emacs)
;;; harness-tools-emacs.el ends here
