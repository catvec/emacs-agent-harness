;;; harness-tools-emacs.el --- Tools that look inside the user's Emacs  -*- lexical-binding: t; -*-

;;; Commentary:

;; Narrow windows into the user's Emacs so a model can help drive it:
;; the buffer and window lists, a buffer's text, showing a buffer or a
;; file where the user can see it, inserting text into a buffer, saving
;; one, the tail of *Messages*, and debugging its Lisp: what a symbol
;; is and holds (its documentation, value, advice, watchers), where it
;; is defined and the source of that definition, and tracing the calls
;; of a function or the changes of a variable while the user works.
;; None of them evaluates code: the elisp tool (tools-shell) evaluates
;; in a background Emacs, and model-written Lisp runs in the user's
;; Emacs only through emacs_eval (tools-emacs-eval), which is off unless
;; the user turns on `harness-emacs-eval' and runs only code a judge
;; model expects to return at once.
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

(defun harness-tools-emacs--where (file)
  "Return where FILE, as the user's Emacs names it, says a definition is.
FILE is a loaded file, \"C source\", or an autoload's library; nil when
no file defined it."
  (and (stringp file)
       (concat "in " (if (file-name-absolute-p file) (abbreviate-file-name file) file))))

(defun harness-tools-emacs--lines (&rest lines)
  "Join LINES with newlines, leaving out the nil ones."
  (string-join (delq nil lines) "\n"))

(defun harness-tools-emacs--describe-function (fn doc)
  "Return the function part of an emacs_describe result for FN.
DOC is FN's documentation, as the result shows it."
  (harness-tools-emacs--lines
   (format "%s: %s" (plist-get fn :kind) (plist-get fn :signature))
   (let ((what (delq nil (list (plist-get fn :definition)
                               (harness-tools-emacs--where (plist-get fn :file))))))
     (and what (string-join what " ")))
   (when-let* ((aliases (plist-get fn :aliases)))
     (format "alias for: %s" (string-join aliases " -> ")))
   (when-let* ((keys (plist-get fn :keys)))
     (format "keys: %s" (string-join keys ", ")))
   (when-let* ((advice (plist-get fn :advice)))
     (format "advice: %s" (string-join advice "; ")))
   doc))

(defun harness-tools-emacs--describe-variable (name var doc)
  "Return the variable part of an emacs_describe result for NAME, from VAR.
DOC is its documentation, as the result shows it."
  (let* ((buffer (plist-get var :buffer))
         (local (harness-json-true-p (plist-get var :local)))
         (count (or (plist-get var :localCount) 0))
         (locals (plist-get var :locals))
         (where (and (> count 0)
                     (format "buffer-local in %d buffer%s: %s%s"
                             count (if (= count 1) "" "s") (string-join locals ", ")
                             (if (> count (length locals)) ", ..." "")))))
    (harness-tools-emacs--lines
     (format "%s: %s" (plist-get var :kind) name)
     (format "value: %s%s" (plist-get var :value)
             (cond ((not (stringp buffer)) "")
                   (local (format " (local to %s)" buffer))
                   ((> count 0) (format " (global; %s has no local value)" buffer))
                   (t "")))
     (and local (stringp (plist-get var :global))
          (format "global value: %s" (plist-get var :global)))
     where
     (when-let* ((standard (plist-get var :standard)))
       (format "changed from its standard value: %s" standard))
     (when-let* ((watchers (plist-get var :watchers)))
       (format "watched by: %s" (string-join watchers ", ")))
     (harness-tools-emacs--where (plist-get var :file))
     doc)))

(defun harness-tools-emacs--format-describe (name answer)
  "Return the emacs_describe result for the symbol NAME from ANSWER."
  (if (not (harness-json-true-p (plist-get answer :known)))
      (harness-tool-error (format "No symbol named %s is known to the user's Emacs" name))
    (let* ((name (string-trim name))
           (doc (lambda (part)
                  (let ((d (plist-get part :doc)))
                    (if (and (stringp d) (not (string-empty-p d))) d "(no documentation)"))))
           (fn (plist-get answer :function))
           (var (plist-get answer :variable))
           (face (plist-get answer :face))
           (parts (delq nil
                        (list (and fn (harness-tools-emacs--describe-function fn (funcall doc fn)))
                              (and var (harness-tools-emacs--describe-variable name var (funcall doc var)))
                              (and face (harness-tools-emacs--lines
                                         (format "face: %s" name)
                                         (harness-tools-emacs--where (plist-get face :file))
                                         (or (plist-get face :doc) "")))))))
      (if parts
          (harness-tool-ok (string-join parts "\n\n"))
        (harness-tool-error (format "%s is neither a function nor a variable" name))))))

(defun harness-tools-emacs--describe (input _ctx)
  "Handler for emacs_describe with INPUT."
  (let ((name (plist-get input :symbol))
        (buffer (plist-get input :buffer)))
    (cond
     ((not (stringp name)) (harness-tool-error "Missing symbol"))
     ((and buffer (not (stringp buffer)))
      (harness-tool-error "Buffer must be a buffer name, as emacs_buffers lists it"))
     (t
      (harness-tools-emacs--ask
       "describe" (list :symbol name
                        :buffer (and (stringp buffer) (not (string-empty-p buffer)) buffer)
                        :maxValueChars harness-tools-emacs--value-chars)
       (lambda (answer) (harness-tools-emacs--format-describe name answer)))))))

(harness-define-tool "emacs_describe"
  :label "Describe symbol"
  :description "Describe an Emacs symbol in the user's live Emacs, as describe-function and describe-variable would. For a function: signature, how it is defined (byte-, native-compiled, interpreted, built-in, autoloaded) and the file it was loaded from, aliases, the keys that run a command, any advice on it (including traces), and its docstring. For a variable: its value in a buffer (truncated), whether it is buffer-local there and in which buffers, its global value, whether it was changed from its standard value, its variable watchers, its file and docstring. For a face: its file and docstring. Use emacs_find_definition for the source of a definition."
  :schema '(:type "object"
            :properties (:symbol (:type "string" :description "The symbol name, e.g. find-file or fill-column")
                         :buffer (:type "string" :description "Buffer whose value of a variable, and whose key bindings of a command, to show, as emacs_buffers lists it. Default: the buffer of the user's selected window"))
            :required ("symbol"))
  :kind 'read
  :coalescable t
  :subject (lambda (input)
             (when-let* ((name (plist-get input :symbol)))
               (if-let* ((buffer (plist-get input :buffer))
                         ((and (stringp buffer) (not (string-empty-p buffer)))))
                   (format "%s in %s" name buffer)
                 name)))
  :handler #'harness-tools-emacs--describe)

;;;; emacs_find_definition

(defun harness-tools-emacs--definition-head (name answer)
  "Return the lines saying what the definition of NAME is, from ANSWER.
ANSWER is what the user's Emacs found."
  (let* ((real (or (plist-get answer :name) name))
         (aliases (plist-get answer :aliases))
         (kind (plist-get answer :kind)))
    (harness-tools-emacs--lines
     (if aliases
         (format "%s is an alias for %s, %s %s"
                 name (string-join aliases ", which is an alias for ")
                 (if (string-match-p "\\`[aeiou]" (or kind "")) "an" "a") kind)
       (format "%s %s: %s" (plist-get answer :type) real kind))
     (when-let* ((loaded (plist-get answer :loaded)))
       (format "loaded from %s" (abbreviate-file-name loaded)))
     (when-let* ((native (plist-get answer :native)))
       (format "native code in %s" (abbreviate-file-name native)))
     (when-let* ((library (plist-get answer :autoload)))
       (format "autoloaded from %s, not loaded yet: this is the source that will load" library))
     (and (harness-json-true-p (plist-get answer :advised))
          "advised: what runs differs from this source; emacs_describe lists the advice"))))

(defun harness-tools-emacs--format-definition (name answer)
  "Return the emacs_find_definition result for the symbol NAME from ANSWER."
  (if (not (harness-json-true-p (plist-get answer :known)))
      (harness-tool-error (format "No symbol named %s is known to the user's Emacs" name))
    (let* ((name (string-trim name))
           (head (harness-tools-emacs--definition-head name answer))
           (file (plist-get answer :file))
           (line (plist-get answer :line))
           (end (plist-get answer :endLine))
           (lines (plist-get answer :lines))
           (note (plist-get answer :note))
           (truncated (harness-json-true-p (plist-get answer :truncated))))
      (cond
       ((harness-json-true-p (plist-get answer :printed))
        (harness-tool-ok
         (format "%s\n%s\n\n%s%s" head (harness-tools-sentence note) (string-join lines "\n")
                 (if truncated (format "\n[stopped at %d characters]" (harness-tools-emacs--buffer-chars)) ""))))
       ((and line lines)
        (let ((last (+ line (length lines) -1)))
          (harness-tool-ok
           (format "%s\ndefined in %s, lines %d-%d%s:\n\n%s%s"
                   head (abbreviate-file-name file) line end
                   (if (harness-json-true-p (plist-get answer :modified))
                       " (as its buffer in the user's Emacs has it, with unsaved changes)"
                     "")
                   (string-join (cl-loop for text in lines for n from line
                                         collect (format "%6d\t%s" n text))
                                "\n")
                   (if truncated
                       (format "\n[stopped at %d characters, at line %d; the definition ends at line %d]"
                               (harness-tools-emacs--buffer-chars) last end)
                     "")))))
       (t
        (harness-tool-ok
         (harness-tools-emacs--lines
          head
          (and (stringp file) (format "file: %s" (abbreviate-file-name file)))
          (and (stringp note) (harness-tools-sentence note)))))))))

(defun harness-tools-emacs--type (value types)
  "Return VALUE, a type input, when it is one of TYPES or empty, else nil.
Empty is nil: the user's Emacs then works out the type from the symbol."
  (cond ((or (null value) (equal value "")) nil)
        ((and (stringp value) (member (downcase value) types)) (downcase value))
        (t :invalid)))

(defun harness-tools-emacs--find-definition (input _ctx)
  "Handler for emacs_find_definition with INPUT."
  (let* ((name (plist-get input :symbol))
         (types '("function" "variable" "face"))
         (type (harness-tools-emacs--type (plist-get input :type) types)))
    (cond
     ((or (not (stringp name)) (string-empty-p (string-trim name)))
      (harness-tool-error "Missing symbol"))
     ((eq type :invalid)
      (harness-tool-error (format "type must be function, variable or face, not %S"
                                  (plist-get input :type))))
     (t
      (harness-tools-emacs--ask
       "definition" (list :symbol name :type type :maxChars (harness-tools-emacs--buffer-chars))
       (lambda (answer) (harness-tools-emacs--format-definition name answer))
       "Search the sources with grep, or ask emacs_describe what the symbol is.")))))

(harness-define-tool "emacs_find_definition"
  :label "Find definition"
  :description "Find where a function, variable or face is defined in the user's live Emacs, as find-function does: what it is, the file it was loaded from (and its native code), and the source file with the line range and text of its definition, numbered. An alias is followed to what it names, an autoload to the library it will load, and a buffer visiting the source is read as it stands, unsaved changes included. A function evaluated outside any file is printed as Emacs holds it. Nothing is visited, shown or run: the source is only read."
  :schema '(:type "object"
            :properties (:symbol (:type "string" :description "The symbol name, e.g. find-file or fill-column")
                         :type (:type "string" :enum ("function" "variable" "face")
                                :description "Which definition of the symbol to find. Default: the function when there is one, else the variable, else the face"))
            :required ("symbol"))
  :kind 'read
  :coalescable t
  :subject (lambda (input)
             (when-let* ((name (plist-get input :symbol)))
               (if-let* ((type (plist-get input :type))
                         ((and (stringp type) (not (string-empty-p type)))))
                   (format "%s %s" type name)
                 name)))
  :handler #'harness-tools-emacs--find-definition)

;;;; emacs_trace

(defconst harness-tools-emacs--trace-default-limit 100
  "Records an emacs_trace trace makes before it stops itself, by default.")

(defconst harness-tools-emacs--trace-max-limit 1000
  "Most records an emacs_trace trace may make.")

(defconst harness-tools-emacs--trace-max-callers 10
  "Most calling functions an emacs_trace record may name.")

(defun harness-tools-emacs--trace-row (trace)
  "Return TRACE, a trace the user's Emacs described, as a line of text."
  (format "%s %s: %s of up to %s %s%s"
          (plist-get trace :type) (plist-get trace :symbol)
          (or (plist-get trace :count) 0) (or (plist-get trace :limit) 0)
          (if (equal (plist-get trace :type) "variable") "changes" "calls")
          (let ((callers (or (plist-get trace :callers) 0)))
            (if (> callers 0)
                (format ", each with up to %d caller%s" callers (if (= callers 1) "" "s"))
              ""))))

(defun harness-tools-emacs--format-trace (action answer)
  "Return the emacs_trace result for ACTION from ANSWER, the Emacs's report."
  (let* ((buffer (or (plist-get answer :buffer) "*trace-output*"))
         (traces (plist-get answer :traces))
         (running (if traces
                      (concat "Running traces:\n"
                              (mapconcat (lambda (trace) (concat "  " (harness-tools-emacs--trace-row trace)))
                                         traces "\n"))
                    "No traces are running."))
         (lines (or (plist-get answer :lines) 0)))
    (harness-tool-ok
     (pcase action
       ("start"
        (let* ((started (plist-get answer :started))
               (variable (equal (plist-get started :type) "variable"))
               (callers (or (plist-get started :callers) 0)))
          (format "%s %s %s in the user's Emacs: from now on each %s is recorded in %s with %s%s, until the trace has recorded %s and stops itself.  Once the user has done what %ss it, read the records with emacs_buffer (name %s, offset %s).  Stop it sooner with action stop%s.\n\n%s"
                  (if variable "Watching" "Tracing")
                  (plist-get started :type) (plist-get started :symbol)
                  (if variable "change" "call") buffer
                  (if variable "its new value" "its arguments, value and time")
                  (if (> callers 0)
                      (if (= callers 1)
                          " and the function that called it"
                        (format " and the %d functions that led to it" callers))
                    "")
                  (format "%s %s" (plist-get started :limit) (if variable "changes" "calls"))
                  (if variable "change" "call") buffer (or (plist-get answer :line) 1)
                  (if variable "" " (M-x untrace-all stops it too)")
                  running)))
       ("stop"
        (let ((stopped (plist-get answer :stopped)))
          (format "%s\n\n%s\n%s has %d lines; read them with emacs_buffer."
                  (if stopped
                      (concat "Stopped:\n"
                              (mapconcat (lambda (trace) (concat "  " (harness-tools-emacs--trace-row trace)))
                                         stopped "\n"))
                    "No such trace was running.")
                  running buffer lines)))
       (_ (format "%s\n%s has %d lines; read them with emacs_buffer." running buffer lines))))))

(defun harness-tools-emacs--trace (input _ctx)
  "Handler for emacs_trace with INPUT."
  (let* ((action (let ((action (plist-get input :action)))
                   (if (or (null action) (equal action "")) "start" (downcase (format "%s" action)))))
         (name (let ((name (plist-get input :symbol)))
                 (and (stringp name) (not (string-empty-p (string-trim name))) (string-trim name))))
         (type (harness-tools-emacs--type (plist-get input :type) '("function" "variable")))
         (limit (harness-tools-emacs--int (plist-get input :limit) harness-tools-emacs--trace-default-limit))
         (callers (harness-tools-emacs--int (plist-get input :callers) 0)))
    (cond
     ((not (member action '("start" "stop" "list")))
      (harness-tool-error (format "action must be start, stop or list, not %S" (plist-get input :action))))
     ((eq type :invalid)
      (harness-tool-error (format "type must be function or variable, not %S" (plist-get input :type))))
     ((and (equal action "start") (not name))
      (harness-tool-error "Missing symbol: name the function or variable to trace"))
     ((and (equal action "start") (not (<= 1 limit harness-tools-emacs--trace-max-limit)))
      (harness-tool-error (format "limit must be between 1 and %d" harness-tools-emacs--trace-max-limit)))
     ((and (equal action "start") (not (<= 0 callers harness-tools-emacs--trace-max-callers)))
      (harness-tool-error (format "callers must be between 0 and %d" harness-tools-emacs--trace-max-callers)))
     (t
      (harness-tools-emacs--ask
       "trace" (list :action action :symbol name :type type :limit limit :callers callers)
       (lambda (answer) (harness-tools-emacs--format-trace action answer))
       :none)))))

(harness-define-tool "emacs_trace"
  :label "Trace symbol"
  :description "Trace a function or watch a variable in the user's live Emacs while they work, to debug it: each call of the function is recorded with its arguments, return value (or non-local exit), nesting and time; each change of the variable (set, let-binding, made void) with its new value and the buffer it is local in. Each record can also name the functions that led to it (callers). Records go to the *trace-output* buffer, which you read with emacs_buffer; values are printed bounded, and a trace stops itself after limit records. action start (the default) starts a trace (replacing one of the same symbol), stop stops one, or every trace when no symbol is given, list lists them. Special forms, macros and the tracing's own functions cannot be traced."
  :schema '(:type "object"
            :properties (:action (:type "string" :enum ("start" "stop" "list")
                                  :description "start (default), stop, or list the running traces")
                         :symbol (:type "string" :description "The function or variable, e.g. find-file or fill-column. Required for start; for stop, none stops every trace")
                         :type (:type "string" :enum ("function" "variable")
                                :description "Trace the function or watch the variable of that name. Default: the function when there is one, else the variable")
                         :callers (:type "integer" :description "How many calling functions each record names, 0-10. Default 0")
                         :limit (:type "integer" :description "Records before the trace stops itself, 1-1000. Default 100")))
  :kind 'write
  :subject (lambda (input)
             (let ((action (or (plist-get input :action) "start"))
                   (name (plist-get input :symbol)))
               (if (and (stringp name) (not (string-empty-p name)))
                   (format "%s %s" action name)
                 action)))
  :handler #'harness-tools-emacs--trace)

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
  :doc "List buffers, List windows, Read buffer, Open buffer, Insert text, Save buffer, Describe symbol, Find definition, Trace symbol and Emacs messages: bounded tools into the user's Emacs, without evaluation."
  :requires '(tools))

(provide 'harness-tools-emacs)
;;; harness-tools-emacs.el ends here
