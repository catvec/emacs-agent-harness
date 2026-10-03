;;; harness-emacs-endpoint.el --- What an Emacs lends the harness  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; Every tool runs in the harness, never in a client.  Some tools are
;; about the user's Emacs -- its buffers, its symbols, its *Messages*
;; and, when the user allows it, evaluating Lisp in it -- and for them
;; that Emacs is a resource the tool reaches, as a TRAMP host is for the
;; file tools.  This file is the Emacs's side of it.
;;
;; An Emacs lends itself to the harness it connects to: the UI puts
;; `harness-emacs-endpoint-client-capabilities' in ACP's `initialize'
;; (clientCapabilities._harness.emacs), as ACP clients offer an agent
;; their files with `fs'.  The harness then sends the requests below to
;; that one Emacs (`emacs/request' in harness-acp.el), never to a client
;; that lends none, such as a phone; with no Emacs lent, a headless
;; harness, those tools say so and every other tool works as usual.
;; `harness-emacs-endpoint-answer' answers them here.  They are a small,
;; fixed vocabulary of data: what the tools check and how they word
;; their results is decided in the harness
;; (lisp/modules/harness-tools-emacs.el), so no tool lives here.
;;
;;   _harness/emacs/buffers  {}
;;     -> (:buffers ((:name :mode :modified :size :file) ...))
;;   _harness/emacs/buffer   {name offset limit maxChars}
;;     -> (:exists :mode :file :modified :total :first :lines :truncated)
;;   _harness/emacs/describe {symbol maxValueChars}
;;     -> (:known :function (:kind :signature :doc)
;;         :variable (:kind :value :doc) :face (:doc))
;;   _harness/emacs/messages {count}
;;     -> (:text)
;;   _harness/emacs/eval     {code timeout}
;;     -> (:value :output :messages :error), as the background Emacs reports
;;
;; The reads are quick and bounded -- a buffer's text and a variable's
;; printed value stop at the size the harness names -- so they never
;; keep this Emacs busy.  `eval' is different: it runs model-written
;; code on this Emacs's only thread, where a blocking call freezes
;; typing and redisplay beyond recovery.  So this Emacs refuses it
;; unless its own `harness-elisp-allow-ui-eval' is on: the Emacs that
;; would freeze decides, whatever harness asks, and by default nothing a
;; model writes runs here (the elisp tool evaluates in a background
;; Emacs instead).
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
(require 'harness-elisp)

(defvar harness-acp-error-method)
(declare-function harness-acp-respond-error "harness-acp" (respond code message &optional data))

(defconst harness-emacs-endpoint--prefix "_harness/emacs/"
  "Prefix of the methods of the requests the harness sends a lent Emacs.")

(defun harness-emacs-endpoint-client-capabilities ()
  "Return the ACP `clientCapabilities' of an Emacs lending itself to the harness.
This client offers none of ACP's own (`fs', `terminal'); `_harness.emacs'
says that it is an Emacs the harness's tools may read, and evaluate in
when this Emacs allows it (see the Commentary)."
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

;;;; eval

(defun harness-emacs-endpoint--eval (params)
  "Evaluate the `:code' of PARAMS in this Emacs, when it allows that.
What `eval' answers: the value, output and messages, or the error the
code signalled, as `harness-elisp-payload' puts them.  The evaluation
stops after `:timeout' seconds when the code yields; code that blocks
cannot be stopped, which is why this is refused unless
`harness-elisp-allow-ui-eval' is on here."
  (unless harness-elisp-allow-ui-eval
    (error "This Emacs does not let the harness evaluate code in it: `harness-elisp-allow-ui-eval' is off, as it is by default, since code that blocks would freeze it"))
  (let ((code (plist-get params :code)))
    (unless (and (stringp code) (not (string-blank-p code)))
      (error "Missing code"))
    (let ((harness-elisp--timeout (harness-emacs-endpoint--int (plist-get params :timeout)
                                                               harness-elisp--timeout 1 3600)))
      (condition-case err
          (harness-elisp-payload (harness-elisp-eval-string code) nil)
        (error (harness-elisp-payload nil (error-message-string err)))))))

;;;; Answering the harness

(defconst harness-emacs-endpoint--methods
  '(("buffers" . harness-emacs-endpoint--buffers)
    ("buffer" . harness-emacs-endpoint--buffer)
    ("describe" . harness-emacs-endpoint--describe)
    ("messages" . harness-emacs-endpoint--messages)
    ("eval" . harness-emacs-endpoint--eval))
  "Request name, after `_harness/emacs/', -> function of its params.")

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
