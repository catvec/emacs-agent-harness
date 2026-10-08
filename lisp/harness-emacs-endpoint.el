;;; harness-emacs-endpoint.el --- What an Emacs lends the harness  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; Every tool runs in the harness, never in a client.  Some tools are
;; about the user's Emacs -- its buffers, its windows, its symbols, its
;; *Messages* and, unless the user turns it off, evaluating Lisp in it --
;; and for them that Emacs is a resource the tool reaches, as a TRAMP
;; host is for the file tools.  This file is the Emacs's side of it.
;;
;; An Emacs lends itself to the harness it connects to: the UI puts
;; `harness-emacs-endpoint-client-capabilities' in ACP's `initialize'
;; (clientCapabilities._harness.emacs), as ACP clients offer an agent
;; their files with `fs'.  The harness then sends the requests below to
;; that one Emacs (`emacs/request' in harness-acp.el), never to a client
;; that lends none, such as a phone; with no Emacs lent, a headless
;; harness, those tools say so and every other tool works as usual.
;; `harness-emacs-endpoint-answer' answers them here.  They are a small,
;; fixed vocabulary of data and bounded work: what the tools check and
;; how they word their results is decided in the harness
;; (lisp/modules/harness-tools-emacs.el), so no tool lives here.
;;
;;   _harness/emacs/buffers  {}
;;     -> (:buffers ((:name :mode :modified :size :file) ...))
;;   _harness/emacs/windows  {}
;;     -> (:windows ((:frame :selected :name :mode :width :height :file) ...))
;;   _harness/emacs/buffer   {name offset limit maxChars}
;;     -> (:exists :mode :file :modified :total :first :lines :truncated)
;;   _harness/emacs/open     {name path line maxBytes}
;;     -> (:name :mode :size :modified :file :visited)
;;   _harness/emacs/insert   {name text position maxChars}
;;     -> (:name :inserted :line)
;;   _harness/emacs/save     {name}
;;     -> (:name :path :size)
;;   _harness/emacs/describe {symbol buffer maxValueChars}
;;     -> (:known :function (:kind :signature :definition :aliases :file
;;                           :advice :keys :doc)
;;         :variable (:kind :value :buffer :local :global :locals
;;                    :localCount :standard :watchers :file :doc)
;;         :face (:doc :file))
;;   _harness/emacs/definition {symbol type maxChars}
;;     -> (:known :type :name :aliases :kind :advised :loaded :native
;;         :autoload :file :visiting :modified :line :endLine :lines
;;         :truncated :printed :note)
;;   _harness/emacs/trace {action symbol type limit callers}
;;     -> (:started (:symbol :type :count :limit :callers) :line
;;         :stopped (...) :traces (...) :buffer :lines)
;;   _harness/emacs/messages {count}
;;     -> (:text)
;;   _harness/emacs/eval     {code timeout deadline host maxChars}
;;     -> (:value :output :messages :error :stopped :seconds), once it ran
;;
;; The reads are quick and bounded -- a buffer's text, a variable's
;; printed value and a definition's text stop at the size the harness
;; names -- so they never keep this Emacs busy.  `definition' reads a
;; source file into a temporary buffer, never visiting it, so none of
;; its code or modes run.  The work requests are bounded too: `open'
;; shows a live buffer or visits an existing local regular file under
;; the size the harness names, never a directory, a remote path or a
;; prompt; `insert' writes text into a live editable buffer and `save'
;; saves one to its local file, turning every question a save could ask
;; (a lock, a missing directory, a file that changed on disk) into an
;; error; `trace' records the calls of a function (an advice, as
;; \\[trace-function] adds) or the changes of a variable (a watcher)
;; into *trace-output*, printing bounded values and stopping itself
;; after the records the harness allows.
;;
;; `eval' is the one request that runs code a model wrote, and it runs
;; it on this Emacs's only thread, where code that blocks freezes typing
;; and redisplay.  So this Emacs refuses it while its own
;; `harness-emacs-eval' is off (it is on by default): the Emacs that
;; would freeze decides, whatever the harness asks.  The harness sends
;; only code a judge model expects to return within a fraction of a
;; second (the emacs_eval tool, lisp/modules/harness-tools-emacs-eval.el),
;; and here that code runs guarded as far as Lisp allows:
;;
;; - It starts only while the user is not typing and no other
;;   evaluation runs, and never once the harness has stopped waiting
;;   for the answer: `deadline' is when it stops, by the harness's
;;   clock, so it counts only when `host' says that clock is this
;;   machine's.
;; - The user's next key stops it (`while-no-input'), C-g included.
;; - It cannot prompt (`inhibit-interaction') or enter the debugger.
;; - It is stopped once it has waited `timeout' seconds, by a timer of
;;   its own that no `catch' in the code can take for its own.
;; - Its value, output and messages come back cut at `maxChars'.
;;
;; Code that neither waits nor reads input, a loop that runs on, can
;; still hold this Emacs until it returns or the user stops it: keeping
;; such code out is the judge's work, the elisp tool evaluates in a
;; background Emacs instead (see harness-elisp.el), and a user who would
;; rather not take the risk turns the setting off.  `eval' is answered
;; once the code has run, not at once like the other requests
;; (`harness-emacs-endpoint--deferred-methods').
;;
;; The UI also asks this file for two chores of its own: saving a
;; harness option in the custom file, and reverting the buffers of a
;; file a tool wrote.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'help-fns)
(require 'find-func)
(require 'harness-core)
(require 'harness-util)
(require 'harness-elisp)

(defvar harness-acp-error-method)
(declare-function harness-acp-respond-error "harness-acp" (respond code message &optional data))

;; trace.el and cl-print.el load when the harness first traces.
(defvar trace-advice-name)
(defvar trace-buffer)
(defvar trace-level)
(defvar inhibit-trace)
(defvar cl-print-string-length)
(declare-function cl-prin1-to-string "cl-print" (object))

(defconst harness-emacs-endpoint--prefix "_harness/emacs/"
  "Prefix of the methods of the requests the harness sends a lent Emacs.")

(defconst harness-emacs-endpoint--open-default-max-bytes (* 8 1024 1024)
  "Largest file `open' visits when the harness names no limit.
Reading a file into this Emacs happens on its only thread, so a larger
file is refused rather than freeze typing and redisplay while it
loads.")

(defconst harness-emacs-endpoint--insert-default-max-chars (* 10 1024 1024)
  "Longest text `insert' accepts when the harness names no limit.
Insertion copies the text on this Emacs's only thread, so a larger text
is refused rather than freeze it moving the text.")

(defun harness-emacs-endpoint-client-capabilities ()
  "Return the ACP `clientCapabilities' of an Emacs lending itself to the harness.
This client offers none of ACP's own (`fs', `terminal'); `_harness.emacs'
says that it is an Emacs the harness's narrow tools may read and drive
(see the Commentary)."
  (list :fs (list :readTextFile :false :writeTextFile :false)
        :terminal :false
        :_harness (list :emacs (list :version emacs-version
                                     :pid (emacs-pid)
                                     :host (system-name)))))

(defun harness-emacs-endpoint--int (value default &optional min max)
  "Return VALUE as an integer within MIN and MAX, or DEFAULT when it is none."
  (let ((n (cond ((integerp value) value)
                 ((numberp value) (truncate value))
                 ((and (stringp value) (string-match-p "\\`-?[0-9]+\\'" value)) (string-to-number value)))))
    (if (null n)
        default
      (when min (setq n (max min n)))
      (when max (setq n (min max n)))
      n)))

(defun harness-emacs-endpoint--bool (value)
  "Return VALUE as a JSON boolean: t, or `:false'."
  (if value t :false))

;;;; buffers

(defun harness-emacs-endpoint--buffers (_params)
  "Describe every live buffer, hidden ones included: what `buffers' answers.
`:file' is the file a buffer visits, or the directory a Dired buffer shows."
  (list :buffers
        (mapcar (lambda (buffer)
                  (with-current-buffer buffer
                    (list :name (buffer-name buffer)
                          :mode (symbol-name major-mode)
                          :modified (harness-emacs-endpoint--bool (buffer-modified-p))
                          :size (buffer-size)
                          :file (or buffer-file-name
                                    (and (derived-mode-p 'dired-mode) default-directory)))))
                (buffer-list))))

;;;; windows

(defun harness-emacs-endpoint--windows (_params)
  "Describe every window of this Emacs, frame by frame: what `windows' answers.
Reading the window tree touches no window's buffer, so it cannot block."
  (list :windows
        (cl-loop for frame in (frame-list)
                 for label from 1
                 append (cl-loop for window in (window-list frame 'nomini)
                                 for buffer = (window-buffer window)
                                 collect (list
                                          :frame label
                                          :selected (harness-emacs-endpoint--bool
                                                     (eq window (selected-window)))
                                          :name (or (buffer-name buffer) "")
                                          :mode (if (buffer-live-p buffer)
                                                    (symbol-name (buffer-local-value 'major-mode buffer))
                                                  "")
                                          :width (window-body-width window)
                                          :height (window-body-height window)
                                          :file (and (buffer-live-p buffer)
                                                     (buffer-local-value 'buffer-file-name buffer)))))))

;;;; buffer

(defun harness-emacs-endpoint--buffer (params)
  "Return the lines of the buffer PARAMS names: what `buffer' answers.
They start at line `:offset' (1-based, default 1), are at most `:limit'
of them (default: to the end) and stop once their text, a newline
counted after each, would pass `:maxChars' characters; `:truncated'
then says so.  A single line longer than that is cut.  The whole buffer
counts, narrowed or not, and its point stays where it is."
  (let* ((name (plist-get params :name))
         (buffer (and (stringp name) (get-buffer name))))
    (if (not (buffer-live-p buffer))
        (list :exists :false)
      (let ((offset (harness-emacs-endpoint--int (plist-get params :offset) 1 1))
            (limit (harness-emacs-endpoint--int (plist-get params :limit) nil 0))
            (max-chars (harness-emacs-endpoint--int (plist-get params :maxChars) nil 1)))
        (with-current-buffer buffer
          (save-excursion
            (save-restriction
              (widen)
              (let* ((total (count-lines (point-min) (point-max)))
                     (last (if limit (min total (+ offset limit -1)) total))
                     (n offset)
                     (taken (progn
                              (goto-char (point-min))
                              (forward-line (1- offset))
                              (harness-emacs-endpoint--take-lines
                               (lambda () (<= (prog1 n (setq n (1+ n))) last))
                               max-chars))))
                (list :exists t
                      :mode (symbol-name major-mode)
                      :file buffer-file-name
                      :modified (harness-emacs-endpoint--bool (buffer-modified-p))
                      :total total
                      :first offset
                      :lines (car taken)
                      :truncated (harness-emacs-endpoint--bool (cdr taken)))))))))))

;;;; open

(defun harness-emacs-endpoint--display-window ()
  "Return a non-minibuffer window to show a buffer in, without prompting.
From an active minibuffer the window it was entered from is used, so a
request that arrives while the user types a minibuffer command still
has a window to show its buffer in."
  (let ((window (if (window-minibuffer-p (selected-window))
                    (or (minibuffer-selected-window)
                        (get-mru-window nil t))
                  (selected-window))))
    (or (and (window-live-p window) window)
        (get-mru-window nil t)
        (selected-window))))

(defun harness-emacs-endpoint--show (buffer &optional line)
  "Show BUFFER in a window, with point at LINE (1-based) when given.
Never prompts: switching goes to the selected window when it can, and
`pop-to-buffer' places BUFFER elsewhere when that window is dedicated
or a minibuffer is active.  Return BUFFER."
  (when (and line (> line 0))
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (goto-char (point-min))
        (forward-line (1- line)))))
  (let ((window (harness-emacs-endpoint--display-window)))
    (with-selected-window window
      (condition-case nil
          (switch-to-buffer buffer)
        (error (pop-to-buffer buffer)))))
  buffer)

(defun harness-emacs-endpoint--open-file (path)
  "Visit PATH in this Emacs and return its buffer, without prompting.
The caller has checked PATH: it is local, existing and a regular file
within the size the harness allows.  Local variables are handled as
with `enable-local-variables' \\=':safe', and `eval:' forms are never
applied or asked about, so a crafted file cannot prompt or run code
through the user's own settings."
  (let ((large-file-warning-threshold nil)
        (enable-local-variables :safe)
        (enable-local-eval nil)
        (inhibit-message t))
    (find-file-noselect path t)))

(defun harness-emacs-endpoint--open (params)
  "Show a buffer or visit a file: what `open' answers.
PARAMS names a live buffer (`:name') or a file (`:path', resolved by
the harness).  A buffer of that name is shown as it is; otherwise the
file is visited first when no buffer has it.  The file must be local,
existing, regular and no larger than `:maxBytes', so nothing here can
prompt or wait on a network or a huge read."
  (let* ((name (plist-get params :name))
         (path (plist-get params :path))
         (line (harness-emacs-endpoint--int (plist-get params :line) nil 1))
         (max-bytes (harness-emacs-endpoint--int (plist-get params :maxBytes)
                                                 harness-emacs-endpoint--open-default-max-bytes 1))
         (buffer (and (stringp name) (get-buffer name)))
         (visited nil))
    (unless (stringp name)
      (error "Missing name"))
    (cond
     (buffer)
     ((not (stringp path)) (error "No buffer named %S" name))
     ((file-remote-p path)
      (error "Refusing to open %s: it is on another host, and visiting it could block this Emacs; read it with read_file instead"
             (abbreviate-file-name path)))
     ((file-directory-p path)
      (error "%s is a directory; list it with list_dir, or open it in dired yourself"
             (abbreviate-file-name path)))
     ((not (file-exists-p path))
      (error "No buffer named %S and no file at %s" name (abbreviate-file-name path)))
     ((not (file-regular-p path))
      (error "Refusing to open %s: it is not a regular file" (abbreviate-file-name path)))
     ((let ((size (harness-file-size path)))
        (and size (> size max-bytes)))
      (error "Refusing to open %s: it is %s, over the %s this tool opens; read it in ranges with read_file"
             (abbreviate-file-name path) (harness-format-bytes (harness-file-size path))
             (harness-format-bytes max-bytes)))
     (t
      (setq visited (not (find-buffer-visiting path))
            buffer (harness-emacs-endpoint--open-file path))))
    (harness-emacs-endpoint--show buffer line)
    (list :name (buffer-name buffer)
          :mode (symbol-name (buffer-local-value 'major-mode buffer))
          :size (buffer-size buffer)
          :modified (harness-emacs-endpoint--bool (buffer-modified-p buffer))
          :file (buffer-local-value 'buffer-file-name buffer)
          :visited (harness-emacs-endpoint--bool visited))))

;;;; insert

(defun harness-emacs-endpoint--editable-p (buffer)
  "Return non-nil when a tool may edit BUFFER.
Hidden buffers (names starting with a space), the minibuffers, the
harness's own UI buffers and *Messages* are not the user's text to
edit: a tool call must not corrupt them or the UI reading them."
  (let ((name (buffer-name buffer)))
    (and name
         (not (string-prefix-p " " name))
         (not (string-prefix-p "*Minibuf" name))
         (not (string-prefix-p "*harness" name))
         (not (equal name "*Messages*")))))

(defun harness-emacs-endpoint--position (value)
  "Return the insert position VALUE names: `point' (default), `start' or `end'."
  (let ((name (and value (downcase (format "%s" value)))))
    (cond ((or (null value) (string-empty-p name) (equal name "point")) 'point)
          ((equal name "start") 'start)
          ((equal name "end") 'end)
          (t (error "position must be point, start or end, not %S" value)))))

(defun harness-emacs-endpoint--insert (params)
  "Insert the `:text' of PARAMS into a buffer: what `insert' answers.
The buffer must be live, editable and not read-only.  `:position' is
point (the default), start or end; `:maxChars' bounds the text.  The
buffer is left modified, not saved, and the answer says from which
line the text starts."
  (let* ((name (plist-get params :name))
         (text (plist-get params :text))
         (where (harness-emacs-endpoint--position (plist-get params :position)))
         (max-chars (harness-emacs-endpoint--int (plist-get params :maxChars)
                                                 harness-emacs-endpoint--insert-default-max-chars 1))
         (buffer (and (stringp name) (get-buffer name))))
    (cond
     ((not (stringp name)) (error "Missing name"))
     ((not (stringp text)) (error "Missing text"))
     ((not (buffer-live-p buffer)) (error "No buffer named %S" name))
     ((not (harness-emacs-endpoint--editable-p buffer))
      (error "Refusing to edit %s: it is a system buffer" name))
     ((> (length text) max-chars)
      (error "Text is %d characters, over the %d this tool inserts" (length text) max-chars))
     (t
      (with-current-buffer buffer
        (when buffer-read-only
          (error "Buffer %s is read-only" name))
        (goto-char (pcase where ('point (point)) ('start (point-min)) ('end (point-max))))
        (let ((start (point)))
          (insert text)
          (list :name name :inserted (length text) :line (line-number-at-pos start))))))))

;;;; save

(defun harness-emacs-endpoint--no-questions (prompt &rest args)
  "Fail instead of asking the user PROMPT with ARGS.
Bound over a tool-driven save: nobody is there to answer, and waiting
would freeze this Emacs behind a prompt the model cannot see."
  (error "Save stopped at a question (%s)" (apply #'format-message prompt args)))

(defun harness-emacs-endpoint--save (params)
  "Save a buffer to the file it visits: what `save' answers.
The buffer must be live and visiting a local file that has not changed
on disk since it was read.  Every question `save-buffer' could ask --
a lock, a missing directory, a changed file -- becomes an error instead
of a prompt."
  (let* ((name (plist-get params :name))
         (buffer (and (stringp name) (get-buffer name))))
    (cond
     ((not (stringp name)) (error "Missing name"))
     ((not (buffer-live-p buffer)) (error "No buffer named %S" name))
     (t
      (with-current-buffer buffer
        (let ((path (buffer-file-name)))
          (cond
           ((null path)
            (error "Buffer %s is not visiting a file; write the text with write_file instead" name))
           ((file-remote-p path)
            (error "Refusing to save %s: it is on another host, and saving it could block this Emacs"
                   (abbreviate-file-name path)))
           ((and (file-exists-p path) (not (verify-visited-file-modtime buffer)))
            (error "Refusing to save %s: the file changed on disk since the buffer was read; revert or reopen it first"
                   (abbreviate-file-name path)))
           (t
            (cl-letf (((symbol-function 'yes-or-no-p) #'harness-emacs-endpoint--no-questions)
                      ((symbol-function 'y-or-n-p) #'harness-emacs-endpoint--no-questions)
                      ((symbol-function 'ask-user-about-supersession-threat)
                       (lambda (file) (error "File %s changed on disk" (abbreviate-file-name file)))))
              (let ((create-lockfiles nil))
                (save-buffer)))
            (list :name name :path path :size (buffer-size))))))))))

;;;; describe

(defun harness-emacs-endpoint--print (value max)
  "Return VALUE printed, cut at MAX characters.
The printing is bounded too, so a huge value cannot keep this Emacs busy."
  (let ((print-length 200) (print-level 10))
    (harness-truncate-end
     (condition-case nil
         (prin1-to-string (if (and (stringp value) (> (length value) max))
                              (substring value 0 max)
                            value))
       (error "#<unprintable>"))
     max)))

(defun harness-emacs-endpoint--symbol (params)
  "Return the symbol the `:symbol' of PARAMS names, or nil when none is interned.
Nothing is interned here: a name this Emacs never read names no symbol."
  (let ((name (plist-get params :symbol)))
    (and (stringp name)
         (not (string-empty-p (string-trim name)))
         (intern-soft (string-trim name)))))

(defun harness-emacs-endpoint--target-buffer (params)
  "Return the buffer the `:buffer' of PARAMS names, by default the user's.
The user's is the buffer of the window they work in (see
`harness-emacs-endpoint--display-window').  A name no live buffer has
is an error."
  (let ((name (plist-get params :buffer)))
    (cond ((or (null name) (equal name ""))
           (window-buffer (harness-emacs-endpoint--display-window)))
          ((and (stringp name) (get-buffer name)))
          (t (error "No buffer named %S" name)))))

(defun harness-emacs-endpoint--name (object)
  "Return the name of the function or symbol OBJECT, for people to read.
A lambda reads as an anonymous function, native-compiled or not."
  (cond ((and object (symbolp object)) (symbol-name object))
        ((and (subrp object) (not (string-search "anonymous_lambda" (subr-name object))))
         (subr-name object))
        ((functionp object) "an anonymous function")
        (t (harness-emacs-endpoint--print object 80))))

(defun harness-emacs-endpoint--unadvised (symbol)
  "Return the definition of the function SYMBOL without aliases or advice.
A macro's is (macro . FUNCTION), an autoload's its autoload object; nil
when SYMBOL is no function."
  (let ((def symbol) (macro nil) (n 0))
    (while (and (< (cl-incf n) 100)
                (or (and def (symbolp def)) (advice--p def) (eq (car-safe def) 'macro)))
      (cond ((eq (car-safe def) 'macro) (setq macro t def (cdr def)))
            ((advice--p def) (setq def (advice--cd*r def)))
            (t (setq def (symbol-function def)))))
    (if (and macro def) (cons 'macro def) def)))

(defun harness-emacs-endpoint--aliases (symbol)
  "Return the functions SYMBOL is an alias for, nearest first.
Unlike `function-alias-p', this looks through advice on an alias."
  (let ((chain nil) (def (symbol-function symbol)) (n 0))
    (while (and def (< (cl-incf n) 100))
      (cond ((advice--p def) (setq def (advice--cd*r def)))
            ((and (symbolp def) (not (eq def symbol)) (not (memq def chain)))
             (push def chain)
             (setq def (symbol-function def)))
            (t (setq def nil))))
    (nreverse chain)))

(defun harness-emacs-endpoint--function-kind (symbol def)
  "Return what the function SYMBOL is, DEF its unadvised definition.
Such as \"native-compiled command\": how it is defined, then what it is."
  (let* ((fn (if (eq (car-safe def) 'macro) (cdr def) def))
         (how (cond ((autoloadp fn) "autoloaded")
                    ((subr-primitive-p fn) "built-in")
                    ((native-comp-function-p fn) "native-compiled")
                    ((byte-code-function-p fn) "byte-compiled")
                    ((interpreted-function-p fn) "interpreted")))
         (what (cond ((special-form-p fn) "special form")
                     ((macrop symbol) "macro")
                     ((commandp symbol) "command")
                     (t "function"))))
    (if how (concat how " " what) what)))

(defun harness-emacs-endpoint--file (symbol type)
  "Return where SYMBOL's definition of TYPE was loaded from, for people to read.
TYPE is `defun', `defvar' or `defface'.  That is the library an
autoload has yet to load, the file `load-history' names (an .elc, say),
\"C source\" for what Emacs defines in C, or nil when no file defined
it: it was evaluated in a buffer, say."
  (pcase type
    ('defun
     (let* ((def (harness-emacs-endpoint--unadvised symbol))
            (fn (if (eq (car-safe def) 'macro) (cdr def) def)))
       (cond ((autoloadp fn) (format "library %s, not loaded yet" (nth 1 fn)))
             ((symbol-file symbol 'defun))
             ((subr-primitive-p fn) "C source"))))
    ('defvar
     (or (symbol-file symbol 'defvar)
         (and (integerp (get symbol 'variable-documentation)) "C source")))
    (_ (symbol-file symbol type))))

(defun harness-emacs-endpoint--advice (symbol)
  "Return the advice on the function SYMBOL as strings, outermost first.
Each says how it runs (:around, :before...) and what runs; the advice
`emacs_trace' and \\[trace-function] add is named for what it does."
  (let ((def (advice--symbol-function symbol))
        (advice nil))
    (when (eq (car-safe def) 'macro) (setq def (cdr def)))
    (while (advice--p def)
      (let ((name (alist-get 'name (advice--props def))))
        (push (format "%s %s" (advice--how def)
                      (cond ((and name (boundp 'trace-advice-name) (eq name trace-advice-name))
                             (if (harness-emacs-endpoint--trace-of symbol 'function)
                                 (format "emacs_trace's trace, recording calls in %s" trace-buffer)
                               "trace-function's trace"))
                            (name (format "%s" name))
                            (t (harness-emacs-endpoint--name (advice--car def)))))
              advice))
      (setq def (advice--cdr def)))
    (nreverse advice)))

(defconst harness-emacs-endpoint--max-keys 8
  "Most key bindings `describe' lists for a command.")

(defun harness-emacs-endpoint--keys (symbol buffer)
  "Return the keys that run the command SYMBOL in BUFFER, as `key-description's.
At most `harness-emacs-endpoint--max-keys', then how many more there
are.  Menu, tool bar and remapping entries are left out, as
`describe-function' leaves them out."
  (when (commandp symbol)
    (with-current-buffer buffer
      (let* ((keys (cl-remove-if (lambda (key)
                                   (and (vectorp key) (> (length key) 0)
                                        (memq (aref key 0) '(menu-bar tool-bar tab-bar remap))))
                                 (where-is-internal symbol)))
             (more (- (length keys) harness-emacs-endpoint--max-keys)))
        (append (mapcar #'key-description (take harness-emacs-endpoint--max-keys keys))
                (and (> more 0) (list (format "%d more" more))))))))

(defun harness-emacs-endpoint--describe-function (symbol &optional buffer)
  "Return SYMBOL described as a function, or nil when it is not one.
Its keys are those that run it in BUFFER, the user's by default."
  (when (fboundp symbol)
    (let* ((args (condition-case nil (help-function-arglist symbol t) (error 'unknown)))
           (doc (condition-case nil (documentation symbol t) (error nil)))
           (def (harness-emacs-endpoint--unadvised symbol))
           (fn (if (eq (car-safe def) 'macro) (cdr def) def))
           (aliases (harness-emacs-endpoint--aliases symbol)))
      (list :kind (cond ((macrop symbol) "macro")
                        ((special-form-p symbol) "special form")
                        ((commandp symbol) "command")
                        ;; Not `subrp': a native-compiled function is a subr too.
                        ((subr-primitive-p fn) "primitive")
                        (t "function"))
            :signature (cond ((eq args 'unknown) (format "%S" (list symbol '\?)))
                             ((listp args) (format "%S" (cons symbol args)))
                             ;; Not loaded yet: the usage its docstring ends with.
                             ((and (stringp doc) (car (help-split-fundoc doc symbol))))
                             (t (format "(%s ...)" symbol)))
            :definition (harness-emacs-endpoint--function-kind symbol def)
            :aliases (mapcar #'symbol-name aliases)
            :file (harness-emacs-endpoint--file symbol 'defun)
            :advice (mapcan #'harness-emacs-endpoint--advice (cons symbol aliases))
            :keys (harness-emacs-endpoint--keys
                   symbol (or buffer (window-buffer (harness-emacs-endpoint--display-window))))
            ;; Without the usage line a docstring ends with, (fn ARGS):
            ;; the signature says it already.
            :doc (or (and (stringp doc) (cdr (help-split-fundoc doc symbol)))
                     doc "")))))

(defconst harness-emacs-endpoint--max-local-buffers 10
  "Most buffers `describe' names where a variable is buffer-local.")

(defun harness-emacs-endpoint--standard-value (symbol max)
  "Return the standard value of the user option SYMBOL printed, or nil.
Nil too when its global value is still that one.  The standard value is
Customize's: the form the option was defined with, evaluated as
`describe-variable' evaluates it.  MAX bounds the printed value."
  (when-let* ((standard (and (custom-variable-p symbol) (default-boundp symbol)
                             (get symbol 'standard-value))))
    (condition-case nil
        (let ((value (eval (car standard) t)))
          (unless (equal value (default-value symbol))
            (harness-emacs-endpoint--print value max)))
      (error nil))))

(defun harness-emacs-endpoint--describe-variable (symbol max &optional buffer)
  "Return SYMBOL described as a variable, or nil when it is not one.
Its value is the one in BUFFER, the user's by default; its global value
is given too when it is buffer-local anywhere.  Every printed value is
cut at MAX characters."
  (when (or (boundp symbol) (get symbol 'variable-documentation))
    (let* ((buffer (or buffer (window-buffer (harness-emacs-endpoint--display-window))))
           (locals (cl-remove-if-not (lambda (b) (local-variable-p symbol b)) (buffer-list))))
      (list :kind (cond ((custom-variable-p symbol) "user option")
                        ((local-variable-if-set-p symbol) "buffer-local variable")
                        (t "variable"))
            :value (if (with-current-buffer buffer (boundp symbol))
                       (harness-emacs-endpoint--print (buffer-local-value symbol buffer) max)
                     "void")
            :buffer (buffer-name buffer)
            :local (harness-emacs-endpoint--bool (local-variable-p symbol buffer))
            :global (and locals
                         (if (default-boundp symbol)
                             (harness-emacs-endpoint--print (default-value symbol) max)
                           "void"))
            :locals (mapcar #'buffer-name (take harness-emacs-endpoint--max-local-buffers locals))
            :localCount (length locals)
            :standard (harness-emacs-endpoint--standard-value symbol max)
            :watchers (mapcar #'harness-emacs-endpoint--watcher-name (get-variable-watchers symbol))
            :file (harness-emacs-endpoint--file symbol 'defvar)
            :doc (or (condition-case nil (documentation-property symbol 'variable-documentation t)
                       (error nil))
                     "")))))

(defun harness-emacs-endpoint--describe (params)
  "Describe the symbol PARAMS names as a function, a variable and a face.
What `describe' answers; `:known' is false when no such symbol exists.
A variable's value and a command's keys are those of the buffer
`:buffer' names, by default the user's (see
`harness-emacs-endpoint--target-buffer')."
  (let* ((symbol (harness-emacs-endpoint--symbol params))
         (buffer (harness-emacs-endpoint--target-buffer params))
         (max (harness-emacs-endpoint--int (plist-get params :maxValueChars) 500 1)))
    (if (null symbol)
        (list :known :false)
      (list :known t
            :function (harness-emacs-endpoint--describe-function symbol buffer)
            :variable (harness-emacs-endpoint--describe-variable symbol max buffer)
            :face (and (facep symbol)
                       (list :doc (or (face-documentation symbol) "")
                             :file (harness-emacs-endpoint--file symbol 'defface)))))))

;;;; definition

;; Where a symbol is defined, and the text of its definition, found as
;; \\[find-function] finds it but without its side effects: the source
;; is read into a temporary buffer, never visited, so no major mode,
;; hook or file-local variable of it runs and no buffer is left behind,
;; and the last resort of `find-function-search-for-symbol', expanding
;; the file's macros, is left out, as it would run the file's code.

(defconst harness-emacs-endpoint--source-max-bytes (* 8 1024 1024)
  "Largest source file `definition' reads.
Reading happens on this Emacs's only thread; Lisp and C sources are far
smaller, so a larger file is not read.")

(defconst harness-emacs-endpoint--pp-max-chars 20000
  "Longest printed definition `definition' pretty-prints.
A longer one is shown as printed, on one line: pretty-printing it would
keep this Emacs busy.")

(defconst harness-emacs-endpoint--no-c-source
  "Emacs's C source is not on this machine (`find-function-C-source-directory' is not set, or names no such file)"
  "What `definition' says of a C definition it cannot show.")

(defun harness-emacs-endpoint--definition-type (value symbol)
  "Return the definition type VALUE names: `function', `variable' or `face'.
Without VALUE, what SYMBOL is: a function when it is one, else a
variable, else a face, else nil."
  (pcase (and (stringp value) (downcase (string-trim value)))
    ((or 'nil "") (cond ((fboundp symbol) 'function)
                        ((or (boundp symbol) (get symbol 'variable-documentation)) 'variable)
                        ((facep symbol) 'face)))
    ("function" 'function)
    ("variable" 'variable)
    ("face" 'face)
    (_ (error "Type must be function, variable or face, not %S" value))))

(defun harness-emacs-endpoint--source-file (library)
  "Return the readable source file of LIBRARY, or nil.
LIBRARY is what `load-history' or an autoload names: a loaded file
\(.elc, .el), a library name, or src/FILE.c for Emacs's C source."
  (if (string-match "\\`src/\\(.*\\.[cm]\\)\\'" library)
      (when (stringp find-function-C-source-directory)
        (let ((file (expand-file-name (match-string 1 library) find-function-C-source-directory)))
          (and (file-readable-p file) file)))
    ;; As `find-function-search-for-symbol': ~/.emacs.el is looked for
    ;; as ~/.emacs too.  `find-library-name' finds an .elc's source.
    (when (string-match "\\.emacs\\(\\.el\\)\\'" library)
      (setq library (substring library 0 (match-beginning 1))))
    (condition-case nil (find-library-name library) (error nil))))

(defun harness-emacs-endpoint--with-source (file fn)
  "Call FN with no argument in a buffer holding FILE's text; return its value.
That is the live buffer visiting FILE when there is one, widened and
its point kept, so a definition being edited is found as it stands;
else a temporary buffer FILE is read into.  FILE is never visited: no
mode, hook or local variable of it runs, and no buffer is left behind.
FN runs with the Emacs Lisp syntax table, comments skipped as space."
  (let ((visiting (find-buffer-visiting file)))
    (if visiting
        (with-current-buffer visiting
          (save-excursion
            (save-restriction
              (widen)
              (with-syntax-table emacs-lisp-mode-syntax-table
                (let ((parse-sexp-ignore-comments t))
                  (funcall fn))))))
      (when (file-remote-p file)
        (error "Refusing to read %s: it is on another host" file))
      (let ((size (harness-file-size file)))
        (when (and size (> size harness-emacs-endpoint--source-max-bytes))
          (error "Refusing to read %s: it is %s, too large for a source file"
                 (abbreviate-file-name file) (harness-format-bytes size))))
      (with-temp-buffer
        (let ((inhibit-message t))
          (insert-file-contents file))
        (with-syntax-table emacs-lisp-mode-syntax-table
          (let ((parse-sexp-ignore-comments t))
            (funcall fn)))))))

(defun harness-emacs-endpoint--search-lisp (symbol type)
  "Return where SYMBOL's definition of TYPE starts in this buffer, or nil.
TYPE is nil for a function, `defvar' or `defface'.  The search is
`find-function-search-for-symbol''s: the regexp or function of
SYMBOL's own `find-function-type-alist', else of
`find-function-regexp-alist', then any form naming SYMBOL first.
Expanding the file's macros, its last resort, is left out."
  (let ((n 0))
    (while (and (< (cl-incf n) 10) (symbolp (get symbol 'definition-name))
                (get symbol 'definition-name))
      (setq symbol (get symbol 'definition-name))))
  (let* ((entry (or (alist-get type (get symbol 'find-function-type-alist))
                    (alist-get type find-function-regexp-alist)))
         ;; (REGEXP-SYMBOL . FORM-MATCHER-FACTORY): the factory is for
         ;; expanding macros, which is not done here.
         (entry (if (functionp (cdr-safe entry)) (car entry) entry))
         (name (symbol-name symbol))
         (case-fold-search nil))
    (goto-char (point-min))
    (when (or (cond ((functionp entry) (ignore-errors (funcall entry symbol)))
                    ((and entry (symbolp entry) (boundp entry) (stringp (symbol-value entry)))
                     (re-search-forward (format (symbol-value entry)
                                                ;; As find-func.el: (defalias (quote \`)...
                                                (concat "\\\\?" (regexp-quote name)))
                                        nil t)))
              (progn (goto-char (point-min))
                     (re-search-forward (concat "^([^ ]+" find-function-space-re "['(]?"
                                                (regexp-quote name) "\\_>")
                                        nil t)))
      (line-beginning-position))))

(defun harness-emacs-endpoint--lisp-span (symbol type)
  "Return (START . END) of SYMBOL's definition of TYPE in this Lisp source, or nil.
TYPE is as for `harness-emacs-endpoint--search-lisp'."
  (when-let* ((start (harness-emacs-endpoint--search-lisp symbol type)))
    (goto-char start)
    (cons start (condition-case nil
                    (progn (forward-sexp 1) (point))
                  ;; Unbalanced: the rest of the file, as far as it is shown.
                  (scan-error (point-max))))))

(defun harness-emacs-endpoint--c-span (symbol type)
  "Return (START . END) of SYMBOL's definition in this C source, or nil.
TYPE is `defvar' for a variable, defined by a DEFVAR_ call; else SYMBOL
is a function, a DEFUN and its body."
  (let ((case-fold-search nil))
    (goto-char (point-min))
    (if (eq type 'defvar)
        (when (re-search-forward (concat "DEFVAR[A-Z_]*[ \t\n]*([ \t\n]*\""
                                         (regexp-quote (symbol-name symbol)) "\"")
                                 nil t)
          (let* ((start (save-excursion (goto-char (match-beginning 0)) (line-beginning-position)))
                 (limit (save-excursion
                          (if (re-search-forward "^[ \t]*DEFVAR\\|^}" nil t) (match-beginning 0) (point-max)))))
            (cons start (if (or (re-search-forward "\\*/[ \t\n]*)[ \t\n]*;" limit t)
                                (re-search-forward ");" limit t))
                            (point)
                          start))))
      (let ((def (harness-emacs-endpoint--unadvised symbol)))
        (when (and (subrp def)
                   (re-search-forward (concat "^DEFUN[ \t\n]*([ \t\n]*\""
                                              (regexp-quote (subr-name def)) "\"")
                                      nil t))
          (let ((start (match-beginning 0)))
            (cons start (if (re-search-forward "^}" nil t) (point) start))))))))

(defun harness-emacs-endpoint--take-lines (more-p max-chars)
  "Return (LINES . TRUNCATED), the lines of this buffer from point on.
They go on while MORE-P, called at the start of each line, returns
non-nil and the buffer has more, and stop once their text, a newline
counted after each, would pass MAX-CHARS characters (nil: no bound);
TRUNCATED then says so.  The first line is always taken, cut when it
alone is longer than MAX-CHARS.  Point moves past the lines taken."
  (let ((chars 0) (lines nil) (truncated nil))
    (while (and (not truncated) (not (eobp)) (funcall more-p))
      (let ((len (- (line-end-position) (point))))
        (if (and max-chars lines (> (+ chars len 1) max-chars))
            ;; The next read starts at this line.
            (setq truncated t)
          (let ((cut (and max-chars (> len max-chars))))
            (push (buffer-substring-no-properties
                   (point) (if cut (+ (point) max-chars) (line-end-position)))
                  lines)
            (setq chars (+ chars (if cut max-chars len) 1)
                  truncated cut)
            (forward-line 1)))))
    (cons (nreverse lines) truncated)))

(defun harness-emacs-endpoint--located (start end max-chars)
  "Return where the text from START to END is, and its lines, for `definition'.
A plist of `:line', `:endLine', `:lines' and `:truncated': the whole
lines of START and END and those between, at most MAX-CHARS of text."
  (save-excursion
    (let* ((start (progn (goto-char start) (line-beginning-position)))
           (end (progn (goto-char end)
                       ;; A text ending in a newline ends on that line.
                       (when (and (bolp) (> (point) start)) (backward-char))
                       (line-end-position)))
           (taken (progn (goto-char start)
                         (harness-emacs-endpoint--take-lines (lambda () (<= (point) end)) max-chars))))
      (list :line (line-number-at-pos start t)
            :endLine (line-number-at-pos end t)
            :lines (car taken)
            :truncated (harness-emacs-endpoint--bool (cdr taken))))))

(defun harness-emacs-endpoint--generated-from (pos)
  "Return the library the autoloads at POS were generated from, or nil.
That is the one the `;;; Generated autoloads from' line above POS names."
  (save-excursion
    (goto-char pos)
    (when (re-search-backward "^;;; Generated autoloads from \\(.+\\)" nil t)
      (file-name-sans-extension (file-name-nondirectory (match-string-no-properties 1))))))

(defun harness-emacs-endpoint--find-in (file symbol type max-chars)
  "Return what a `definition' answer says of SYMBOL's definition in FILE.
TYPE is nil for a function, `defvar' or `defface'; MAX-CHARS bounds
the text.  A definition found in an autoloads file is looked for again
in the library it was generated from."
  (let* ((c (string-match-p "\\.[cm]\\'" file))
         (autoloads (string-match-p "loaddefs\\|-autoloads" (file-name-nondirectory file)))
         (visiting (find-buffer-visiting file))
         (from nil)
         (found (harness-emacs-endpoint--with-source
                 file
                 (lambda ()
                   (when-let* ((span (if c
                                         (harness-emacs-endpoint--c-span symbol type)
                                       (harness-emacs-endpoint--lisp-span symbol type))))
                     (when autoloads
                       (setq from (harness-emacs-endpoint--generated-from (car span))))
                     (harness-emacs-endpoint--located (car span) (cdr span) max-chars)))))
         (source (and from (harness-emacs-endpoint--source-file from)))
         (again (and source (not (equal source file))
                     (ignore-errors (harness-emacs-endpoint--find-in source symbol type max-chars)))))
    (if (plist-get again :line)
        again
      (append (list :file file
                    :visiting (harness-emacs-endpoint--bool visiting)
                    :modified (harness-emacs-endpoint--bool (and visiting (buffer-modified-p visiting))))
              (or found
                  (list :note (format "Searching %s finds no definition of %s: a macro may define it under another name"
                                      (abbreviate-file-name file) symbol)))))))

(defun harness-emacs-endpoint--printed-definition (symbol def max-chars)
  "Return what a `definition' answer says of the function SYMBOL no file defines.
DEF is its unadvised definition.  An interpreted one is printed as the
`defun' or `defmacro' it amounts to, at most MAX-CHARS of it; a
compiled one has no source left."
  (let* ((macro (eq (car-safe def) 'macro))
         (fn (if macro (cdr def) def)))
    (if (not (interpreted-function-p fn))
        (list :note (format "No file defines %s: it was evaluated outside one, and only its compiled code is left"
                            symbol))
      ;; An interpreted closure with neither docstring nor interactive
      ;; form has only its first three slots.
      (let* ((doc (and (> (length fn) 4) (aref fn 4)))
             (spec (interactive-form fn))
             (form `(,(if macro 'defmacro 'defun) ,symbol ,(aref fn 0)
                     ,@(and (stringp doc) (list doc))
                     ,@(and spec (list spec))
                     ,@(aref fn 1)))
             (printed (let ((print-length nil) (print-level nil) (print-circle t))
                        (prin1-to-string form)))
             (text (if (> (length printed) harness-emacs-endpoint--pp-max-chars)
                       printed
                     (let ((print-circle t)) (pp-to-string form)))))
        (with-temp-buffer
          (insert text)
          (append (list :printed t
                        :note (format "No file defines %s: it was evaluated outside one, and this is the definition Emacs holds"
                                      symbol))
                  (harness-emacs-endpoint--located (point-min) (point-max) max-chars)))))))

(defun harness-emacs-endpoint--source-part (library find)
  "Return the part of a `definition' answer for a definition in LIBRARY.
FIND is called with LIBRARY's source file when there is one; else the
answer says why there is no source to show."
  (let ((source (harness-emacs-endpoint--source-file library)))
    (cond (source (funcall find source))
          ((string-prefix-p "src/" library)
           (list :file library :note harness-emacs-endpoint--no-c-source))
          (t (list :note (format "Its source, %s, is not on the load path" library))))))

(defun harness-emacs-endpoint--function-definition (symbol max-chars)
  "Return what a `definition' answer says of the function SYMBOL.
MAX-CHARS bounds the text of the definition."
  (unless (fboundp symbol) (error "%s is not a function" symbol))
  (let* ((aliases (harness-emacs-endpoint--aliases symbol))
         (real (or (car (last aliases)) symbol))
         (def (harness-emacs-endpoint--unadvised real))
         (fn (if (eq (car-safe def) 'macro) (cdr def) def))
         (library (cond ((autoloadp fn) (nth 1 fn))
                        ((subr-primitive-p fn) (ignore-errors (help-C-file-name fn 'subr)))
                        ((symbol-file real 'defun)))))
    (append
     (list :name (symbol-name real)
           :aliases (mapcar #'symbol-name aliases)
           :kind (harness-emacs-endpoint--function-kind real def)
           :advised (harness-emacs-endpoint--bool
                     (cl-some #'harness-emacs-endpoint--advice (cons symbol aliases)))
           :loaded (and (not (autoloadp fn)) (not (subr-primitive-p fn)) library)
           :native (and (native-comp-function-p fn) (symbol-file real 'defun t))
           :autoload (and (autoloadp fn) (format "%s" (nth 1 fn))))
     (if library
         (harness-emacs-endpoint--source-part
          library (lambda (file) (harness-emacs-endpoint--find-in file real nil max-chars)))
       (harness-emacs-endpoint--printed-definition real def max-chars)))))

(defun harness-emacs-endpoint--variable-definition (symbol max-chars)
  "Return what a `definition' answer says of the variable SYMBOL.
MAX-CHARS bounds the text of the definition."
  (let ((library (or (symbol-file symbol 'defvar)
                     (and (integerp (get symbol 'variable-documentation))
                          (ignore-errors (help-C-file-name symbol 'var))))))
    (append
     (list :name (symbol-name symbol)
           :kind (cond ((custom-variable-p symbol) "user option")
                       ((local-variable-if-set-p symbol) "buffer-local variable")
                       (t "variable"))
           :loaded (and library (not (string-prefix-p "src/" library)) library))
     (if library
         (harness-emacs-endpoint--source-part
          library (lambda (file) (harness-emacs-endpoint--find-in file symbol 'defvar max-chars)))
       (list :note (format "No file defines %s: it was only set, or defined outside a file"
                           symbol))))))

(defun harness-emacs-endpoint--face-definition (symbol max-chars)
  "Return what a `definition' answer says of the face SYMBOL.
MAX-CHARS bounds the text of the definition."
  (unless (facep symbol) (error "%s is not a face" symbol))
  (let ((library (symbol-file symbol 'defface)))
    (append
     (list :name (symbol-name symbol) :kind "face" :loaded library)
     (if library
         (harness-emacs-endpoint--source-part
          library (lambda (file) (harness-emacs-endpoint--find-in file symbol 'defface max-chars)))
       (list :note (format "No file defines %s: it is built in, or was defined outside a file"
                           symbol))))))

(defun harness-emacs-endpoint--definition (params)
  "Find the definition of the symbol PARAMS names: what `definition' answers.
`:type' is function, variable or face (default: what the symbol is)
and `:maxChars' bounds the text of the definition.  Its source is read,
never visited, and none of its code runs (see
`harness-emacs-endpoint--with-source')."
  (let ((symbol (harness-emacs-endpoint--symbol params))
        (max-chars (harness-emacs-endpoint--int (plist-get params :maxChars) 20000 1)))
    (if (null symbol)
        (list :known :false)
      (let ((type (or (harness-emacs-endpoint--definition-type (plist-get params :type) symbol)
                      (error "%s is neither a function, a variable nor a face" symbol))))
        (append (list :known t :type (symbol-name type))
                (pcase type
                  ('function (harness-emacs-endpoint--function-definition symbol max-chars))
                  ('variable (harness-emacs-endpoint--variable-definition symbol max-chars))
                  ('face (harness-emacs-endpoint--face-definition symbol max-chars))))))))

;;;; trace

;; A trace records what a function or a variable goes through while the
;; user works, into trace.el's buffer, *trace-output*: each call of a
;; function with its arguments, then its value (or its non-local exit)
;; and how long it took; or each change of a variable, through a
;; variable watcher, with the buffer it is local in.  A record can name
;; the functions that led to it too.  It is not trace.el's tracing,
;; which prints whole values and runs until it is undone: printing is
;; bounded, a trace stops itself after its limit of records, and
;; `inhibit-trace' keeps the recording from recording itself.  The
;; advice of a function's trace carries trace.el's name, so
;; \\[untrace-function] and \\[untrace-all] stop it as they stop the
;; user's own traces.

(cl-defstruct (harness-emacs-endpoint--tracer
               (:constructor harness-emacs-endpoint--tracer-make)
               (:copier nil))
  "A trace the harness started in this Emacs.
SYMBOL is traced as TYPE, `function' or `variable', by FN, its advice or
its watcher.  It stops itself after LIMIT records, COUNT made so far,
each naming up to CALLERS calling functions; STOPPED once it stopped."
  symbol type fn limit (count 0) (callers 0) stopped)

(defvar harness-emacs-endpoint--traces nil
  "The traces the harness started and has not stopped, newest first.")

(defconst harness-emacs-endpoint--trace-default-limit 100
  "Records a trace makes before it stops itself, unless the harness names a limit.")

(defconst harness-emacs-endpoint--trace-max-limit 1000
  "Most records a trace may make.")

(defconst harness-emacs-endpoint--trace-max-callers 10
  "Most calling functions a record may name.")

(defconst harness-emacs-endpoint--max-traces 20
  "Most traces the harness may run at once.")

(defconst harness-emacs-endpoint--trace-line-chars 1000
  "Longest record line; a longer one is cut.")

(defconst harness-emacs-endpoint--untraceable '(apply funcall)
  "Functions a trace refuses: its advice calls them before it can tell.")

(defconst harness-emacs-endpoint--unwatchable '(inhibit-trace trace-level)
  "Variables a trace refuses to watch: recording any record binds them.")

(defun harness-emacs-endpoint--trace-of (symbol type)
  "Return the running trace of SYMBOL as TYPE, `function' or `variable', or nil."
  (cl-find-if (lambda (trace)
                (and (eq (harness-emacs-endpoint--tracer-symbol trace) symbol)
                     (eq (harness-emacs-endpoint--tracer-type trace) type)))
              harness-emacs-endpoint--traces))

(defun harness-emacs-endpoint--watcher-name (watcher)
  "Return the name of the variable watcher WATCHER, for people to read."
  (if (cl-find watcher harness-emacs-endpoint--traces :key #'harness-emacs-endpoint--tracer-fn)
      (format "emacs_trace's watcher, recording changes in %s" trace-buffer)
    (harness-emacs-endpoint--name watcher)))

(defun harness-emacs-endpoint--trace-label (trace)
  "Return what TRACE traces, such as \"function find-file\"."
  (format "%s %s" (harness-emacs-endpoint--tracer-type trace)
          (harness-emacs-endpoint--tracer-symbol trace)))

(defun harness-emacs-endpoint--trace-unit (trace)
  "Return what TRACE counts: \"calls\" of a function, \"changes\" of a variable."
  (if (eq (harness-emacs-endpoint--tracer-type trace) 'function) "calls" "changes"))

(defun harness-emacs-endpoint--trace-print (value max)
  "Return VALUE printed for a trace record, at most MAX characters.
Printing is bounded too: 10 elements of a list or vector, 3 levels
deep, 120 characters of a string."
  (let ((print-length 10) (print-level 3) (print-escape-newlines t)
        (print-escape-control-characters t) (cl-print-string-length 120))
    (harness-truncate-end
     (condition-case nil
         (substring-no-properties (cl-prin1-to-string value))
       (error "#<unprintable>"))
     max)))

(defconst harness-emacs-endpoint--trace-plumbing '(apply funcall set set-default)
  "Functions a record's callers leave out: they pass a call or a change on.")

(defun harness-emacs-endpoint--trace-own-p (func fns)
  "Return non-nil when the frame of FUNC is the tracing's own.
That is one of the functions recording a call, or FNS, the advice and
watchers of the traces."
  (or (memq func fns)
      (and (symbolp func)
           (string-prefix-p "harness-emacs-endpoint--trace" (symbol-name func)))))

(defun harness-emacs-endpoint--trace-stack (n anchor)
  "Return the names of the N functions nearest up the stack from ANCHOR's frame.
ANCHOR is the traced function's symbol, or the watcher: the frames below
it are the recording's.  Left out are the plumbing of a call
\(`harness-emacs-endpoint--trace-plumbing', special forms of interpreted
code), the frames of the tracing itself, and the original definition a
trace's advice calls, whose symbol's frame comes next.  The walk gives
up after 200 frames."
  (let ((frames nil) (found nil) (depth 0)
        (fns (mapcar #'harness-emacs-endpoint--tracer-fn harness-emacs-endpoint--traces))
        (names nil))
    (catch 'harness-emacs-endpoint--trace-stack
      (mapbacktrace
       (lambda (evald func _args _flags)
         (when (> (cl-incf depth) 200)
           (throw 'harness-emacs-endpoint--trace-stack nil))
         (if (not found)
             (setq found (eq func anchor))
           (when evald (push func frames))))
       #'harness-emacs-endpoint--trace-stack))
    (setq frames (nreverse frames))
    (while (and frames (< (length names) n))
      (let ((func (pop frames)))
        (unless (or (memq func harness-emacs-endpoint--trace-plumbing)
                    (harness-emacs-endpoint--trace-own-p func fns)
                    (and (not (symbolp func))
                         (harness-emacs-endpoint--trace-own-p
                          (cl-find-if-not (lambda (f) (memq f harness-emacs-endpoint--trace-plumbing))
                                          frames)
                          fns)))
          (push (harness-emacs-endpoint--name func) names))))
    (nreverse names)))

(defun harness-emacs-endpoint--trace-from (trace anchor)
  "Return the callers a record of TRACE names, as \"  ; from F < G\", or \"\".
F called the traced function, or changed the variable, and G called F.
ANCHOR is as for `harness-emacs-endpoint--trace-stack'."
  (let* ((n (harness-emacs-endpoint--tracer-callers trace))
         (names (and (> n 0) (harness-emacs-endpoint--trace-stack n anchor))))
    (if names (concat "  ; from " (string-join names " < ")) "")))

(defun harness-emacs-endpoint--trace-insert (line)
  "Append LINE to the trace buffer, cut when it is too long.
Too long is `harness-emacs-endpoint--trace-line-chars'.  Windows
showing the buffer follow, and the user's mark stays active, as with
trace.el.  The buffer keeps no undo when the harness made it."
  (let ((buffer (or (get-buffer trace-buffer)
                    (with-current-buffer (get-buffer-create trace-buffer)
                      (buffer-disable-undo)
                      (current-buffer)))))
    (with-current-buffer buffer
      (setq-local window-point-insertion-type t)
      (save-restriction
        (widen)
        (goto-char (point-max))
        (let ((deactivate-mark nil) (inhibit-read-only t))
          (insert (harness-truncate-end line harness-emacs-endpoint--trace-line-chars) "\n"))))))

(defun harness-emacs-endpoint--trace-indent (level)
  "Return the indentation of a record LEVEL calls deep, as trace.el indents."
  (if (> level 1)
      (concat (mapconcat #'identity (make-list (1- level) "|") " ") " ")
    ""))

(defun harness-emacs-endpoint--trace-tally (trace)
  "Count a record of TRACE, and stop TRACE when that reaches its limit.
Its advice or watcher is removed from a timer, out of the call or
change being recorded, and the trace buffer then says why."
  (when (>= (cl-incf (harness-emacs-endpoint--tracer-count trace))
            (harness-emacs-endpoint--tracer-limit trace))
    (setf (harness-emacs-endpoint--tracer-stopped trace) t)
    (run-at-time 0 nil #'harness-emacs-endpoint--trace-finish trace)))

(defun harness-emacs-endpoint--trace-finish (trace)
  "Remove TRACE, stopped at its limit, and say so in the trace buffer."
  (harness-emacs-endpoint--trace-remove trace)
  (let ((inhibit-trace t))
    (harness-emacs-endpoint--trace-insert
     (format ";; harness: stopped tracing %s after %d %s, its limit"
             (harness-emacs-endpoint--trace-label trace)
             (harness-emacs-endpoint--tracer-count trace)
             (harness-emacs-endpoint--trace-unit trace)))))

(defun harness-emacs-endpoint--trace-call (trace orig args)
  "Call ORIG with ARGS and return its value, recording the call in TRACE.
The record is the call as trace.el writes it, then its callers when
TRACE asks for them; then, once ORIG returns or exits non-locally, its
value or that exit and how long it took."
  (let ((symbol nil) (level nil) (start nil) (done nil) (value nil))
    ;; Bound before any function is called, so a traced function the
    ;; recording calls does not record itself.
    (let ((inhibit-trace t))
      (setq symbol (harness-emacs-endpoint--tracer-symbol trace)
            level (1+ trace-level))
      (harness-emacs-endpoint--trace-insert
       (format "%s%d -> %s%s" (harness-emacs-endpoint--trace-indent level) level
               (harness-emacs-endpoint--trace-print (cons symbol args) 600)
               (harness-emacs-endpoint--trace-from trace symbol)))
      (harness-emacs-endpoint--trace-tally trace)
      (setq start (float-time)))
    (unwind-protect
        (let ((trace-level level))
          (setq value (apply orig args)
                done t)
          value)
      (let ((inhibit-trace t))
        (harness-emacs-endpoint--trace-insert
         (format "%s%d <- %s: %s  ; %.2f ms" (harness-emacs-endpoint--trace-indent level) level
                 symbol
                 (if done (harness-emacs-endpoint--trace-print value 300) "!non-local exit!")
                 (* 1000 (- (float-time) start))))))))

(defun harness-emacs-endpoint--trace-advice (trace)
  "Return the :around advice recording the calls TRACE is about.
It calls straight through while `inhibit-trace' is on, as it is while a
record is written, and once TRACE has stopped."
  (lambda (orig &rest args)
    (if (or inhibit-trace (harness-emacs-endpoint--tracer-stopped trace))
        (apply orig args)
      (harness-emacs-endpoint--trace-call trace orig args))))

(defun harness-emacs-endpoint--trace-change (trace symbol newval operation where)
  "Record in TRACE that SYMBOL is about to change to NEWVAL by OPERATION.
WHERE is the buffer of a buffer-local change, else nil: the arguments
of a variable watcher (see `add-variable-watcher')."
  (let ((inhibit-trace t))
    (harness-emacs-endpoint--trace-insert
     (format "%s= %s %s%s%s"
             (harness-emacs-endpoint--trace-indent (1+ trace-level))
             symbol
             (pcase operation
               ('set (format "set to %s" (harness-emacs-endpoint--trace-print newval 300)))
               ('let (format "let-bound to %s" (harness-emacs-endpoint--trace-print newval 300)))
               ('unlet (format "back to %s after a let"
                               (harness-emacs-endpoint--trace-print newval 300)))
               ;; With a buffer, `kill-local-variable' and the like:
               ;; the default value shows through again.
               ('makunbound (if (buffer-live-p where) "lost its local value" "made void"))
               ('defvaralias (format "made an alias of %s" newval))
               (_ (format "%s %s" operation (harness-emacs-endpoint--trace-print newval 300))))
             (if (buffer-live-p where) (format " in %s" (buffer-name where)) "")
             (harness-emacs-endpoint--trace-from trace (harness-emacs-endpoint--tracer-fn trace))))
    (harness-emacs-endpoint--trace-tally trace)))

(defun harness-emacs-endpoint--trace-watcher (trace)
  "Return the variable watcher recording the changes TRACE is about."
  (lambda (symbol newval operation where)
    (unless (or inhibit-trace (harness-emacs-endpoint--tracer-stopped trace))
      (harness-emacs-endpoint--trace-change trace symbol newval operation where))))

(defun harness-emacs-endpoint--trace-live-p (trace)
  "Return non-nil when TRACE runs: not stopped, its advice or watcher in place.
\\[untrace-all] or `remove-variable-watcher' may have removed it."
  (let ((symbol (harness-emacs-endpoint--tracer-symbol trace))
        (fn (harness-emacs-endpoint--tracer-fn trace)))
    (and (not (harness-emacs-endpoint--tracer-stopped trace))
         (if (eq (harness-emacs-endpoint--tracer-type trace) 'function)
             (advice-member-p fn symbol)
           (memq fn (get-variable-watchers symbol))))))

(defun harness-emacs-endpoint--trace-remove (trace)
  "Remove TRACE's advice or watcher, and forget TRACE."
  (setf (harness-emacs-endpoint--tracer-stopped trace) t)
  (let ((symbol (harness-emacs-endpoint--tracer-symbol trace))
        (fn (harness-emacs-endpoint--tracer-fn trace)))
    (ignore-errors
      (if (eq (harness-emacs-endpoint--tracer-type trace) 'function)
          (advice-remove symbol fn)
        (remove-variable-watcher symbol fn))))
  (setq harness-emacs-endpoint--traces (delq trace harness-emacs-endpoint--traces)))

(defun harness-emacs-endpoint--trace-prune ()
  "Forget the traces that stopped at their limit or were removed by hand."
  (dolist (trace harness-emacs-endpoint--traces)
    (unless (harness-emacs-endpoint--trace-live-p trace)
      (harness-emacs-endpoint--trace-remove trace))))

(defun harness-emacs-endpoint--trace-row (trace)
  "Return TRACE described for an answer."
  (list :symbol (symbol-name (harness-emacs-endpoint--tracer-symbol trace))
        :type (symbol-name (harness-emacs-endpoint--tracer-type trace))
        :count (harness-emacs-endpoint--tracer-count trace)
        :limit (harness-emacs-endpoint--tracer-limit trace)
        :callers (harness-emacs-endpoint--tracer-callers trace)))

(defun harness-emacs-endpoint--trace-lines ()
  "Return how many lines the trace buffer has, 0 when there is none."
  (let ((buffer (get-buffer trace-buffer)))
    (if (buffer-live-p buffer)
        (with-current-buffer buffer
          (save-restriction (widen) (count-lines (point-min) (point-max))))
      0)))

(defun harness-emacs-endpoint--trace-check (symbol type)
  "Signal an error when SYMBOL cannot be traced as TYPE, `function' or `variable'."
  (pcase type
    ('function
     (cond ((not (fboundp symbol)) (error "%s is not a function" symbol))
           ((special-form-p symbol)
            (error "%s is a special form, which cannot be traced; trace a function that uses it"
                   symbol))
           ((macrop symbol)
            (error "%s is a macro, which runs when code is expanded, not when it runs; trace a function instead"
                   symbol))
           ((or (memq symbol harness-emacs-endpoint--untraceable)
                (string-prefix-p "harness-emacs-endpoint--trace" (symbol-name symbol)))
            (error "Tracing %s would trace the tracing itself" symbol))
           ((and (advice-member-p trace-advice-name symbol)
                 (not (harness-emacs-endpoint--trace-of symbol 'function)))
            (error "%s is traced already, by trace-function; its calls go to %s"
                   symbol trace-buffer))))
    ('variable
     (cond ((memq symbol harness-emacs-endpoint--unwatchable)
            (error "Watching %s would watch the tracing itself" symbol))
           ((or (keywordp symbol) (memq symbol '(nil t)))
            (error "%s is a constant, which never changes" symbol)))))
  (when (and (not (harness-emacs-endpoint--trace-of symbol type))
             (>= (length harness-emacs-endpoint--traces) harness-emacs-endpoint--max-traces))
    (error "%d traces are running already; stop one first"
           (length harness-emacs-endpoint--traces))))

(defun harness-emacs-endpoint--trace-add (symbol type limit callers)
  "Start tracing SYMBOL as TYPE, `function' or `variable'; return the trace.
It makes LIMIT records at most, each naming up to CALLERS calling
functions.  A trace of SYMBOL as TYPE already running is replaced."
  (harness-emacs-endpoint--trace-check symbol type)
  (when-let* ((old (harness-emacs-endpoint--trace-of symbol type)))
    (harness-emacs-endpoint--trace-remove old))
  (let ((trace (harness-emacs-endpoint--tracer-make :symbol symbol :type type
                                                    :limit limit :callers callers)))
    (setf (harness-emacs-endpoint--tracer-fn trace)
          (if (eq type 'function)
              (harness-emacs-endpoint--trace-advice trace)
            (harness-emacs-endpoint--trace-watcher trace)))
    (if (eq type 'function)
        (advice-add symbol :around (harness-emacs-endpoint--tracer-fn trace)
                    `((name . ,trace-advice-name) (depth . -100)))
      (add-variable-watcher symbol (harness-emacs-endpoint--tracer-fn trace)))
    (push trace harness-emacs-endpoint--traces)
    trace))

(defun harness-emacs-endpoint--trace-start (params name symbol)
  "Start the trace PARAMS asks for, of SYMBOL, named NAME.
Return that part of the `trace' answer."
  (unless name (error "Missing symbol"))
  (unless symbol (error "No symbol named %s is known to this Emacs" name))
  (let* ((type (pcase (harness-emacs-endpoint--definition-type (plist-get params :type) symbol)
                 ('function 'function)
                 ('variable 'variable)
                 ('face (error "A face cannot be traced; trace a function or a variable"))
                 (_ (error "%s is neither a function nor a variable; give type variable to watch it all the same"
                           symbol))))
         (limit (harness-emacs-endpoint--int (plist-get params :limit)
                                             harness-emacs-endpoint--trace-default-limit
                                             1 harness-emacs-endpoint--trace-max-limit))
         (callers (harness-emacs-endpoint--int (plist-get params :callers) 0
                                               0 harness-emacs-endpoint--trace-max-callers))
         (trace (harness-emacs-endpoint--trace-add symbol type limit callers))
         (line (1+ (harness-emacs-endpoint--trace-lines))))
    (let ((inhibit-trace t))
      (harness-emacs-endpoint--trace-insert
       (format ";; harness: tracing %s, up to %d %s%s"
               (harness-emacs-endpoint--trace-label trace) limit
               (harness-emacs-endpoint--trace-unit trace)
               (if (> callers 0)
                   (format ", each with up to %d caller%s" callers (if (= callers 1) "" "s"))
                 ""))))
    (list :started (harness-emacs-endpoint--trace-row trace) :line line)))

(defun harness-emacs-endpoint--trace-stop (params name symbol)
  "Stop the traces PARAMS names, of SYMBOL, named NAME.
With no NAME, every trace stops; `:type' narrows them to a function's
or a variable's.  Return that part of the `trace' answer."
  (let* ((type (let ((type (plist-get params :type)))
                 (and (stringp type) (not (string-empty-p type)) (downcase type))))
         (stopped (cl-remove-if-not
                   (lambda (trace)
                     (and (or (null name) (eq (harness-emacs-endpoint--tracer-symbol trace) symbol))
                          (or (null type)
                              (equal type (symbol-name (harness-emacs-endpoint--tracer-type trace))))))
                   harness-emacs-endpoint--traces)))
    (dolist (trace stopped)
      (harness-emacs-endpoint--trace-remove trace)
      (let ((inhibit-trace t))
        (harness-emacs-endpoint--trace-insert
         (format ";; harness: stopped tracing %s after %d %s"
                 (harness-emacs-endpoint--trace-label trace)
                 (harness-emacs-endpoint--tracer-count trace)
                 (harness-emacs-endpoint--trace-unit trace)))))
    (list :stopped (mapcar #'harness-emacs-endpoint--trace-row stopped))))

(defun harness-emacs-endpoint--trace (params)
  "Start, stop or list the harness's traces: what `trace' answers.
PARAMS: `:action' start (the default), stop or list; `:symbol', which
stop may leave out to stop every trace; `:type' function or variable
\(default: what the symbol is); `:limit', the records before a trace
stops itself; `:callers', the calling functions each record names.
The answer lists the traces running, the trace buffer and its line
count; start's says on which line its trace's records begin, stop's
which traces it stopped."
  (require 'trace)
  (require 'cl-print)
  (harness-emacs-endpoint--trace-prune)
  (let* ((action (let ((action (plist-get params :action)))
                   (if (or (null action) (equal action "")) "start" (downcase (format "%s" action)))))
         (name (let ((name (plist-get params :symbol)))
                 (and (stringp name) (not (string-empty-p (string-trim name))) (string-trim name))))
         (symbol (harness-emacs-endpoint--symbol params))
         (answer (pcase action
                   ("start" (harness-emacs-endpoint--trace-start params name symbol))
                   ("stop" (harness-emacs-endpoint--trace-stop params name symbol))
                   ("list" nil)
                   (_ (error "Action must be start, stop or list, not %S" action)))))
    (append answer
            (list :traces (mapcar #'harness-emacs-endpoint--trace-row
                                  (reverse harness-emacs-endpoint--traces))
                  :buffer trace-buffer
                  :lines (harness-emacs-endpoint--trace-lines)))))

;;;; messages

(defun harness-emacs-endpoint--messages (params)
  "Return the last lines of *Messages*: what `messages' answers.
As many as the `:count' of PARAMS says, 50 by default."
  (let ((count (harness-emacs-endpoint--int (plist-get params :count) 50 1 100000)))
    (with-current-buffer (messages-buffer)
      (save-excursion
        (goto-char (point-max))
        (forward-line (- count))
        (list :text (string-trim-right (buffer-substring-no-properties (point) (point-max))))))))

;;;; eval

(defcustom harness-emacs-eval t
  "Non-nil lets agents evaluate Emacs Lisp in this Emacs, while you use it.
Sessions then get the emacs_eval tool, which runs a model's code here
rather than in a background Emacs, so it can change this one: define a
function, set a variable, fix up a buffer.  Each call passes the
permission checks a shell command does, then a judge model must expect
the code to return within a fraction of a second; the code may not
prompt, stops at your next key (\\[keyboard-quit] included), and is
stopped once it has waited two seconds.

On by default.  The code runs on this Emacs's only thread, so code
that never waits, such as a loop the judge misjudged, holds it until it
returns or you stop it.  Turn this off to keep model-written code out
of this Emacs: the elisp tool still evaluates in a background Emacs,
and the other emacs_* tools still read and drive this one.

Set it on the settings page, or in your init file before the harness
starts.  Only the global value counts, and this Emacs refuses to
evaluate while it is off here, whatever the harness asks."
  :type 'boolean :group 'harness)

(defun harness-emacs-eval-p ()
  "Non-nil when `harness-emacs-eval' is on: its global value, never a buffer's."
  (and (default-value 'harness-emacs-eval) t))

(defconst harness-emacs-endpoint--eval-default-timeout 2
  "Seconds code `eval' runs may wait when the harness names no limit.")

(defconst harness-emacs-endpoint--eval-max-timeout 10
  "Most seconds code `eval' runs may wait, whatever the harness asks.")

(defconst harness-emacs-endpoint--eval-max-code-chars 100000
  "Longest code `eval' accepts; the harness sends far less.")

(defconst harness-emacs-endpoint--eval-default-max-chars 10000
  "Characters of the value, the output and the messages `eval' sends back.
Each is cut at this many when the harness names no limit.")

(defconst harness-emacs-endpoint--eval-retry 0.05
  "Seconds `eval' waits before it looks again for a moment to start in.")

(defconst harness-emacs-endpoint--eval-min-time 0.1
  "Seconds `eval' needs before the harness's deadline to start code at all.")

(defvar harness-emacs-endpoint--evaluating nil
  "Non-nil while `eval' runs code here; another evaluation waits for it.
Evaluations never nest: code that waits lets other requests in, and a
second evaluation would run inside the first one's guards.")

(defun harness-emacs-endpoint--input-pending-p ()
  "Non-nil when the user has typed something this Emacs has not read yet."
  (input-pending-p))

(defun harness-emacs-endpoint--seconds (value default max)
  "Return VALUE as positive seconds no more than MAX, or DEFAULT."
  (if (and (numberp value) (> value 0)) (min value max) default))

(defun harness-emacs-endpoint--eval-deadline (params now timeout)
  "Return when `eval' with PARAMS gives up starting its code, as a time.
That is the harness's `:deadline' when it was read on this machine's
clock, which `:host' says by naming this machine as the function
`system-name' does, else NOW plus TIMEOUT seconds."
  (let ((deadline (plist-get params :deadline)))
    (if (and (numberp deadline) (equal (plist-get params :host) (system-name)))
        deadline
      (+ now timeout))))

(defun harness-emacs-endpoint--eval-text (buffer max)
  "Return the text of BUFFER, without properties, cut at MAX characters."
  (with-current-buffer buffer
    (harness-truncate-end
     (string-trim-right
      (buffer-substring-no-properties (point-min) (min (point-max) (+ (point-min) max 1))))
     max)))

(defun harness-emacs-endpoint--eval-run (forms limit max)
  "Evaluate FORMS here, guarded, and return what `eval' answers.
FORMS may wait LIMIT seconds before they are stopped; the value, the
output and the messages are each cut at MAX characters.  Nil when the
user was typing as the evaluation was to start, so nothing ran.  The
guards are those of the Commentary: the user's next key, \\[keyboard-quit]
included, stops the code, it may not prompt or enter the debugger, and
a timer of its own stops it once it has waited LIMIT seconds."
  (let ((out (generate-new-buffer " *harness-eval-output*" t))
        (messages-start (harness-elisp--messages-end))
        (tag (make-symbol "harness-eval-timeout"))
        (begin (float-time))
        (started nil) (stopped nil) (failure nil) (printed ""))
    (setq harness-emacs-endpoint--evaluating t)
    (unwind-protect
        (let ((result
               ;; Requests arrive in a process filter or a timer, where
               ;; quitting is inhibited, and `while-no-input' allows it
               ;; for the code alone.  Bound here too, so the same holds
               ;; when this is called from anywhere else.
               (let ((inhibit-quit t))
                 (or (while-no-input
                       (setq started t)
                       (when (eq tag
                                 (catch tag
                                   (let ((timer (run-with-timer limit nil (lambda () (throw tag tag))))
                                         (standard-output out)
                                         (message-log-max t)
                                         (inhibit-message t)
                                         (inhibit-interaction t)
                                         (debug-on-error nil)
                                         (debug-on-quit nil)
                                         (debug-on-signal nil)
                                         (debug-on-message nil)
                                         (value nil))
                                     (unwind-protect
                                         (condition-case err
                                             (progn
                                               (dolist (form forms)
                                                 (setq value (eval form t)))
                                               (setq printed (harness-emacs-endpoint--print value max)))
                                           (error (setq failure (error-message-string err))))
                                       (cancel-timer timer)))
                                   nil))
                         (setq stopped "timeout"))
                       'done)
                     ;; C-g, which `while-no-input''s `with-local-quit'
                     ;; caught and set `quit-flag' again for, so that an
                     ;; outer command quits too.  There is none: the
                     ;; quit was for this code alone, and it is cleared
                     ;; while quitting is still inhibited, or it would
                     ;; quit whatever runs next.
                     (progn (setq quit-flag nil) 'quit)))))
          (pcase result
            ('done)
            ('quit (setq stopped "quit"))
            (_ (setq stopped "input")))
          (when started
            (list :value printed
                  :output (harness-emacs-endpoint--eval-text out max)
                  :messages (harness-truncate-end (harness-elisp--messages-since messages-start) max)
                  :error failure
                  :stopped stopped
                  :seconds (/ (round (* 1000 (- (float-time) begin))) 1000.0))))
      (setq harness-emacs-endpoint--evaluating nil)
      (kill-buffer out))))

(defun harness-emacs-endpoint--eval-start (forms timeout max deadline waited answer fail)
  "Run FORMS for `eval' once this Emacs is free, by DEADLINE at the latest.
Free means the user is not typing and no other evaluation runs; until
then this looks again every `harness-emacs-endpoint--eval-retry'
seconds, and WAITED says it has.  The code may wait TIMEOUT seconds,
and no longer than DEADLINE leaves; MAX bounds what comes back.
ANSWER gets the report, FAIL a message when the code does not run, or
when it leaves the evaluation by a non-local exit, such as a call of
the function `top-level'."
  (let ((now (float-time)))
    (cond
     ((> (+ now harness-emacs-endpoint--eval-min-time) deadline)
      (funcall fail
               (cond ((eq waited 'busy)
                      "Not run: another evaluation kept the user's Emacs busy until the harness stopped waiting, so nothing was evaluated")
                     (waited
                      "Not run: the user was typing until the harness stopped waiting, so nothing was evaluated")
                     (t
                      "Not run: the request reached the user's Emacs only after the harness had stopped waiting for it (that Emacs was busy), so nothing was evaluated"))))
     ((or harness-emacs-endpoint--evaluating (harness-emacs-endpoint--input-pending-p))
      (run-at-time harness-emacs-endpoint--eval-retry nil
                   #'harness-emacs-endpoint--eval-start forms timeout max deadline
                   (if harness-emacs-endpoint--evaluating 'busy 'typing) answer fail))
     (t
      (let ((report nil) (failure nil) (exited t))
        (unwind-protect
            (progn
              ;; The code's own errors are part of the report; this is
              ;; for one of the evaluation's, which would leave the
              ;; request unanswered from a timer.
              (condition-case err
                  (setq report (harness-emacs-endpoint--eval-run forms (min timeout (- deadline now)) max))
                (error (setq failure (error-message-string err))))
              (setq exited nil))
          (when exited
            (ignore-errors
              (funcall fail "The code left the evaluation by a non-local exit (such as `top-level'), so what it did is not known"))))
        (cond
         (failure (funcall fail (format "The evaluation failed in the user's Emacs: %s" failure)))
         (report (funcall answer report))
         ;; The user typed just as it was to start: nothing ran yet.
         (t (run-at-time harness-emacs-endpoint--eval-retry nil
                         #'harness-emacs-endpoint--eval-start forms timeout max deadline
                         'typing answer fail))))))))

(defun harness-emacs-endpoint--eval (params answer fail)
  "Evaluate the `:code' of PARAMS in this Emacs: what `eval' answers.
Refused unless `harness-emacs-eval' is on here.  The code is read
whole first, so code that does not read runs not at all.  It then
runs as the Commentary says, once this Emacs is free, and ANSWER gets
the report: the printed value, the output, the messages, the error
the code signalled and why it was stopped (`timeout', `input' or
`quit'), each nil when there is none, and the seconds it took.  FAIL
gets a message when the code does not run."
  (unless (harness-emacs-eval-p)
    ;; Verbatim, not through `format-message', which would curl the
    ;; apostrophe and quotes of a message the model reads.
    (signal 'error (list "The user's Emacs does not let agents evaluate Lisp in it: the user turned `harness-emacs-eval' off there")))
  (let ((code (plist-get params :code)))
    (unless (and (stringp code) (not (string-blank-p code)))
      (error "Missing code"))
    (when (> (length code) harness-emacs-endpoint--eval-max-code-chars)
      (error "The code is longer than %d characters" harness-emacs-endpoint--eval-max-code-chars))
    (let* ((forms (condition-case err
                      (harness-elisp-read-forms code)
                    (error (error "The code does not read: %s" (error-message-string err)))))
           (timeout (harness-emacs-endpoint--seconds (plist-get params :timeout)
                                                     harness-emacs-endpoint--eval-default-timeout
                                                     harness-emacs-endpoint--eval-max-timeout))
           (max (harness-emacs-endpoint--int (plist-get params :maxChars)
                                             harness-emacs-endpoint--eval-default-max-chars 100))
           (deadline (harness-emacs-endpoint--eval-deadline params (float-time) timeout)))
      (harness-emacs-endpoint--eval-start forms timeout max deadline nil answer fail))))

;;;; Answering the harness

(defconst harness-emacs-endpoint--methods
  '(("buffers" . harness-emacs-endpoint--buffers)
    ("windows" . harness-emacs-endpoint--windows)
    ("buffer" . harness-emacs-endpoint--buffer)
    ("open" . harness-emacs-endpoint--open)
    ("insert" . harness-emacs-endpoint--insert)
    ("save" . harness-emacs-endpoint--save)
    ("describe" . harness-emacs-endpoint--describe)
    ("definition" . harness-emacs-endpoint--definition)
    ("trace" . harness-emacs-endpoint--trace)
    ("messages" . harness-emacs-endpoint--messages))
  "Request name, after `_harness/emacs/', -> function of its params.
Each answers at once, and none evaluates code: the one request that
does, `eval', is in `harness-emacs-endpoint--deferred-methods'.")

(defconst harness-emacs-endpoint--deferred-methods
  '(("eval" . harness-emacs-endpoint--eval))
  "Request name -> function of its params, an answer and a failure function.
These answer once their work is done, which may be after the request
was read: the function calls the answer function with the result, or
the failure function with a message, once; an error it signals at
once fails the request too.")

(defun harness-emacs-endpoint-handle (name params)
  "Return the answer to the request NAME (such as \"buffers\") with PARAMS.
Signal an error for a request this Emacs refuses or does not know, and
for one that answers later (see `harness-emacs-endpoint--deferred-methods'),
which only `harness-emacs-endpoint-answer' can answer."
  (let ((fn (cdr (assoc name harness-emacs-endpoint--methods))))
    (unless fn
      (if (assoc name harness-emacs-endpoint--deferred-methods)
          (error "The request %s answers later, through `harness-emacs-endpoint-answer'" name)
        (error "This Emacs answers no request %s" name)))
    (funcall fn params)))

(defun harness-emacs-endpoint-answer (method params respond)
  "Answer METHOD with PARAMS through RESPOND when it is a request for this Emacs.
Return non-nil when METHOD is one of the `_harness/emacs/' requests (see
the Commentary), nil for any other method, which is left to the caller.
A request this Emacs refuses or cannot answer gets a JSON-RPC error.
Most are answered before this returns; `eval' is answered once its
code has run, or once it is clear that it will not."
  (when (string-prefix-p harness-emacs-endpoint--prefix method)
    (when respond
      (let* ((name (substring method (length harness-emacs-endpoint--prefix)))
             (deferred (cdr (assoc name harness-emacs-endpoint--deferred-methods)))
             (answered nil)
             (answer (lambda (result)
                       (unless answered
                         (setq answered t)
                         (funcall respond result))))
             (fail (lambda (message)
                     (unless answered
                       (setq answered t)
                       (harness-acp-respond-error respond harness-acp-error-method message)))))
        (condition-case err
            (if deferred
                (funcall deferred params answer fail)
              (funcall answer (harness-emacs-endpoint-handle name params)))
          (error (funcall fail (error-message-string err))))))
    t))

;;;; Chores of the UI

(declare-function harness-policy-refuse "harness-policy" (option))

(defun harness-emacs-endpoint-customize-save (name printed)
  "Save the user option NAME with the value read from PRINTED in `custom-file'.
Only `harness-' options: the request comes from the harness process.
One the policy sets (see harness-policy.el) is refused."
  (unless (and (stringp name) (string-prefix-p "harness-" name))
    (error "Refusing to save %s: not a harness option" name))
  ;; Module options are not defined in the UI's Emacs, so intern the name.
  (let ((sym (intern name)))
    (when (fboundp 'harness-policy-refuse)
      (harness-policy-refuse sym))
    (customize-save-variable sym (car (read-from-string printed)))
    t))

(defun harness-emacs-endpoint-revert-visiting (path)
  "Revert an unmodified live buffer visiting PATH so it shows the new content."
  (let ((buf (and (stringp path) (find-buffer-visiting path))))
    (when (and buf (buffer-live-p buf) (not (buffer-modified-p buf)))
      (with-current-buffer buf
        (harness-ignore-errors-logged "revert after tool write"
          (revert-buffer :ignore-auto :noconfirm :preserve-modes))))))

(provide 'harness-emacs-endpoint)
;;; harness-emacs-endpoint.el ends here
