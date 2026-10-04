;;; harness-emacs-endpoint.el --- What an Emacs lends the harness  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; Every tool runs in the harness, never in a client.  Some tools are
;; about the user's Emacs -- its buffers, its windows, its symbols and
;; its *Messages* -- and for them that Emacs is a resource the tool
;; reaches, as a TRAMP host is for the file tools.  This file is the
;; Emacs's side of it.
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
;;   _harness/emacs/describe {symbol maxValueChars}
;;     -> (:known :function (:kind :signature :doc)
;;         :variable (:kind :value :doc) :face (:doc))
;;   _harness/emacs/messages {count}
;;     -> (:text)
;;
;; The reads are quick and bounded -- a buffer's text and a variable's
;; printed value stop at the size the harness names -- so they never
;; keep this Emacs busy.  The work requests are bounded too: `open'
;; shows a live buffer or visits an existing local regular file under
;; the size the harness names, never a directory, a remote path or a
;; prompt; `insert' writes text into a live editable buffer and `save'
;; saves one to its local file, turning every question a save could ask
;; (a lock, a missing directory, a file that changed on disk) into an
;; error.  Nothing here evaluates code: model-written Lisp never runs
;; in this Emacs (the elisp tool evaluates in a background Emacs; see
;; harness-elisp.el), and there is no request that could.
;;
;; The UI also asks this file for two chores of its own: saving a
;; harness option in the custom file, and reverting the buffers of a
;; file a tool wrote.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'help-fns)
(require 'harness-core)
(require 'harness-util)

(defvar harness-acp-error-method)
(declare-function harness-acp-respond-error "harness-acp" (respond code message &optional data))

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
                     (n offset) (chars 0) (lines nil) (truncated nil))
                (goto-char (point-min))
                (forward-line (1- offset))
                (while (and (<= n last) (not (eobp)) (not truncated))
                  (let ((len (- (line-end-position) (point))))
                    (if (and max-chars lines (> (+ chars len 1) max-chars))
                        ;; The next call starts at this line.
                        (setq truncated t)
                      ;; The first line is always read, cut when it alone is too long.
                      (let ((cut (and max-chars (> len max-chars))))
                        (push (buffer-substring-no-properties
                               (point) (if cut (+ (point) max-chars) (line-end-position)))
                              lines)
                        (setq chars (+ chars (if cut max-chars len) 1)
                              n (1+ n)
                              truncated cut)
                        (forward-line 1)))))
                (list :exists t
                      :mode (symbol-name major-mode)
                      :file buffer-file-name
                      :modified (harness-emacs-endpoint--bool (buffer-modified-p))
                      :total total
                      :first offset
                      :lines (nreverse lines)
                      :truncated (harness-emacs-endpoint--bool truncated))))))))))

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

(defun harness-emacs-endpoint--describe-function (symbol)
  "Return SYMBOL described as a function, or nil when it is not one."
  (when (fboundp symbol)
    (let ((args (condition-case nil (help-function-arglist symbol t) (error 'unknown)))
          (doc (condition-case nil (documentation symbol t) (error nil))))
      (list :kind (cond ((macrop symbol) "macro")
                        ((special-form-p symbol) "special form")
                        ((commandp symbol) "command")
                        ((subrp (symbol-function symbol)) "primitive")
                        (t "function"))
            :signature (format "%S" (cons symbol (if (eq args 'unknown) '(\?) args)))
            :doc (or doc "")))))

(defun harness-emacs-endpoint--describe-variable (symbol max)
  "Return SYMBOL described as a variable, or nil.
Its printed value is cut at MAX characters."
  (when (or (boundp symbol) (get symbol 'variable-documentation))
    (list :kind (cond ((custom-variable-p symbol) "user option")
                      ((local-variable-if-set-p symbol) "buffer-local variable")
                      (t "variable"))
          :value (if (boundp symbol) (harness-emacs-endpoint--print (symbol-value symbol) max) "void")
          :doc (or (condition-case nil (documentation-property symbol 'variable-documentation t)
                     (error nil))
                   ""))))

(defun harness-emacs-endpoint--describe (params)
  "Describe the symbol PARAMS names as a function, a variable and a face.
What `describe' answers; `:known' is false when no such symbol exists."
  (let* ((name (plist-get params :symbol))
         (symbol (and (stringp name) (intern-soft (string-trim name))))
         (max (harness-emacs-endpoint--int (plist-get params :maxValueChars) 500 1)))
    (if (null symbol)
        (list :known :false)
      (list :known t
            :function (harness-emacs-endpoint--describe-function symbol)
            :variable (harness-emacs-endpoint--describe-variable symbol max)
            :face (and (facep symbol) (list :doc (or (face-documentation symbol) "")))))))

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

;;;; Answering the harness

(defconst harness-emacs-endpoint--methods
  '(("buffers" . harness-emacs-endpoint--buffers)
    ("windows" . harness-emacs-endpoint--windows)
    ("buffer" . harness-emacs-endpoint--buffer)
    ("open" . harness-emacs-endpoint--open)
    ("insert" . harness-emacs-endpoint--insert)
    ("save" . harness-emacs-endpoint--save)
    ("describe" . harness-emacs-endpoint--describe)
    ("messages" . harness-emacs-endpoint--messages))
  "Request name, after `_harness/emacs/', -> function of its params.
No entry evaluates code: model-written Lisp never runs in this Emacs,
so there is no request that could run it.")

(defun harness-emacs-endpoint-handle (name params)
  "Return the answer to the request NAME (such as \"buffers\") with PARAMS.
Signal an error for a request this Emacs refuses or does not know."
  (let ((fn (cdr (assoc name harness-emacs-endpoint--methods))))
    (unless fn (error "This Emacs answers no request %s" name))
    (funcall fn params)))

(defun harness-emacs-endpoint-answer (method params respond)
  "Answer METHOD with PARAMS through RESPOND when it is a request for this Emacs.
Return non-nil when METHOD is one of the `_harness/emacs/' requests (see
the Commentary), nil for any other method, which is left to the caller.
A request this Emacs refuses or cannot answer gets a JSON-RPC error."
  (when (string-prefix-p harness-emacs-endpoint--prefix method)
    (when respond
      (condition-case err
          (funcall respond (harness-emacs-endpoint-handle
                            (substring method (length harness-emacs-endpoint--prefix)) params))
        (error (harness-acp-respond-error respond harness-acp-error-method (error-message-string err)))))
    t))

;;;; Chores of the UI

(defun harness-emacs-endpoint-customize-save (name printed)
  "Save the user option NAME with the value read from PRINTED in `custom-file'.
Only `harness-' options: the request comes from the harness process."
  (unless (and (stringp name) (string-prefix-p "harness-" name))
    (error "Refusing to save %s: not a harness option" name))
  ;; Module options are not defined in the UI's Emacs, so intern the name.
  (let ((sym (intern name)))
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
