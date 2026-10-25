;;; harness-snapshot.el --- A copy of the user's Emacs, in slices  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The `elisp' tool can start its background Emacs from a copy of the
;; user's: the values of the variables the user's Emacs has and the
;; text of its buffers, to compute over.  Its code changes the copy, and
;; the user's Emacs not at all.  This file is the user's Emacs's side of
;; it, the `snapshot' request of lisp/harness-emacs-endpoint.el: it
;; reads that Emacs and gives the copy away as text, in slices.  The
;; background Emacs reads the text back (lisp/harness-elisp.el), and
;; lisp/modules/harness-tools-shell.el puts the two together and
;; decides how the child runs.
;;
;; Nothing here evaluates anything.  The request carries a cursor and
;; two sizes, and the answer is data: `harness-snapshot-slice' walks
;; values (never calling a function of the user's, never an accessor,
;; never a printer a package extends), copies them into plain Lisp
;; data, and prints that.
;;
;; The user's Emacs has one thread, so the copy is made in slices: each
;; request works for about `harness-snapshot-slice-seconds' and answers
;; with a chunk of text, the cursor of the next, and whether that was
;; the last.  The first request lists the symbols that have a value
;; (up to about a tenth of a second in an Emacs with tens of thousands
;; of them, once) and every other one visits what it can in its time.
;; What the cursor stands for is kept here for a minute at most, and an
;; abandoned copy is dropped by the next request or by `release'.
;;
;; The text.  A chunk is forms to be read, one after another:
;;
;;   (snapshot :version 1 :time T :emacs-version V :system-type S
;;             :system-configuration C :features (F ...))
;;   (b :name N :mode MODE :file F :directory D :point P :modified M
;;      :size S :text-from A :text-to B :locals ((VAR . VALUE) ...)
;;      :locals-cut K :text "...")                  ; each live buffer
;;   (v VAR VALUE)                                  ; each variable
;;   (manifest :variables N ... :withheld-variables (NAME ...) ...)
;;
;; in that order, the last once, at the end; its keys say what was left
;; out and why (see `harness-snapshot--manifest').  A value is the
;; user's value as data, printed with `print-circle' and escapes so
;; that the text is plain ASCII.  What the user's value held and data
;; cannot be becomes `#s(harness-user-object KIND "DESCRIPTION")': a
;; buffer, marker, window, frame, process, overlay, subr, function
;; (byte-code included, which a reader must never turn back into code),
;; char-table, obarray and the like.  Text properties are dropped.  A
;; value too big, in the sense of `harness-snapshot-variable-chars', is
;; `#s(harness-user-truncated "NAME" SIZE)'.
;;
;; Credentials.  The user's Emacs holds what the user typed and what its
;; packages keep: passwords, tokens, the cache of auth-source.  The copy
;; goes to a model, so it leaves those out by NAME, and says only that it
;; did: a variable whose name matches `harness-snapshot-withheld-regexp'
;; is not in the copy, and the manifest lists its name, never its value;
;; a buffer that is named for credentials or visits a file that is
;; (`harness-snapshot-withheld-buffers-regexp') is left out the same
;; way.  The environment is kept entry by entry: a variable of
;; `process-environment' whose name looks like a credential has its value
;; withheld.  Both options are the user's to extend.  This is not a
;; promise that the copy holds no secret: a name cannot tell what a
;; value is.  What remains is documented in docs/trust-model.md.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup harness-snapshot nil
  "A copy of the user's Emacs for the elisp tool."
  :group 'harness)

(defcustom harness-snapshot-withheld-regexp
  (concat
   ;; What the name says it is.
   "password\\|passwd\\|passphrase\\|token\\|secret\\|api[-_]?key\\|credential\\|cookie"
   "\\|private[-_]?key\\|signing-key\\|session-key\\|access-key\\|auth-key\\|oauth\\|bearer"
   ;; What Emacs's packages keep for authentication.
   "\\|auth-source\\|authinfo\\|plstore\\|\\`epa-\\|\\`epg-\\|\\`tramp-cache\\|\\`url-cookie"
   ;; What the harness itself holds that is not named for it.
   "\\|\\`harness-\\(?:acp-remote\\|acp--clients\\|redact\\|redaction\\|secrets\\|oidc\\|snapshot--\\)"
   ;; What the user typed or copied.
   "\\|\\`kill-ring\\|-history\\'\\|-ring\\'\\|\\`register-alist\\'\\|\\`last-kbd-macro\\'")
  "Variables whose names match this regexp are left out of the copy.
The match ignores case.  A name that matches is listed in the copy's
manifest, never its value.  The option `harness-config-secret-regexp'
of the harness, where it is defined, withholds besides.  Extend this
one for what only you keep: the names of your own tokens and caches."
  :type 'regexp
  :group 'harness-snapshot)

(defcustom harness-snapshot-withheld-buffers-regexp
  (concat
   "authinfo\\|\\.netrc\\|_netrc\\|\\.gpg\\>\\|\\.asc\\>\\|\\.pgpass\\|\\.htpasswd"
   "\\|id_rsa\\|id_ed25519\\|id_ecdsa\\|id_dsa\\|\\.pem\\>\\|\\.p12\\>\\|\\.pfx\\>\\|\\.key\\>"
   "\\|\\.password-store\\|password\\|passwd\\|secret\\|credential\\|token"
   "\\|/\\.ssh/\\|/\\.aws/\\|/\\.kube/\\|kubeconfig\\|k3s\\.yaml\\|\\.docker/config"
   "\\|\\.npmrc\\|\\.pypirc\\|\\.env\\>\\|\\.envrc")
  "Buffers named, or visiting a file named, like this are left out of the copy.
The match ignores case and is made against the buffer's name and the
name of the file it visits.  The manifest lists the names of the
buffers left out, never their text."
  :type 'regexp
  :group 'harness-snapshot)

(defconst harness-snapshot-version 1
  "The version of the text `harness-snapshot-slice' gives.")

(defconst harness-snapshot-variable-chars (* 64 1024)
  "Longest printed value of a variable the copy keeps.
A longer one is `#s(harness-user-truncated \"NAME\" SIZE)'.")

(defconst harness-snapshot-local-chars (* 16 1024)
  "Longest printed buffer-local value the copy keeps.")

(defconst harness-snapshot-locals-chars (* 128 1024)
  "Most characters of buffer-local values the copy keeps for one buffer.")

(defconst harness-snapshot-locals-count 300
  "Most buffer-local variables the copy keeps for one buffer.")

(defconst harness-snapshot-buffer-chars (* 1024 1024)
  "Most characters of a buffer's text the copy keeps.
A longer buffer is cut to the part round point, and the buffer's entry
says which.")

(defconst harness-snapshot-max-buffers 300
  "Most live buffers the copy holds, the most recently used first.")

(defconst harness-snapshot-max-chars (* 16 1024 1024)
  "Most characters the whole copy holds.")

(defconst harness-snapshot-buffers-chars (* 4 1024 1024)
  "Most characters of `harness-snapshot-max-chars' the buffers take.
They come before the variables, and what they leave is the variables'.")

(defconst harness-snapshot-slice-seconds 0.025
  "Seconds one request works, unless it names another, up to a quarter.")

(defconst harness-snapshot-slice-chars (* 256 1024)
  "Characters one chunk holds, more or less, unless the request names another.
A chunk stops after the item that reaches it, so it may be longer by one
item; the largest an item is is `harness-snapshot-buffer-chars'.")

(defconst harness-snapshot-walk-nodes 20000
  "Most pieces of a value the copy visits before it gives the value up.
This bounds the work one value costs, whatever it is.")

(defconst harness-snapshot-idle-seconds 60
  "How long what a cursor stands for is kept without another request.")

(defconst harness-snapshot-max-states 2
  "Most copies in the making at once; starting another drops the oldest.")

(defconst harness-snapshot-withheld-listed 2000
  "Most names of withheld variables the manifest lists.")

;;;; What a name says

(defconst harness-snapshot--never-withheld '("load-history")
  "Names the regexp of withheld variables does not hold back.
`load-history' ends in `-history' like the lists of what the user typed,
and holds only the names of files and symbols.")

(defun harness-snapshot--withheld-name-p (name)
  "Non-nil when the variable NAME, a string, is left out of the copy."
  (let ((case-fold-search t))
    (or (and (not (member name harness-snapshot--never-withheld))
             (string-match-p harness-snapshot-withheld-regexp name))
        (let ((extra (and (boundp 'harness-config-secret-regexp)
                          (symbol-value 'harness-config-secret-regexp))))
          (and (stringp extra) (string-match-p extra name))))))

(defun harness-snapshot--withheld-buffer-p (buffer)
  "Non-nil when BUFFER is named for credentials, or visits a file that is."
  (let ((case-fold-search t)
        (file (buffer-local-value 'buffer-file-name buffer)))
    (or (string-match-p harness-snapshot-withheld-buffers-regexp (buffer-name buffer))
        (and (stringp file)
             (string-match-p harness-snapshot-withheld-buffers-regexp file)))))

(defun harness-snapshot--withheld-env-p (entry)
  "Non-nil when ENTRY, a string of `process-environment', holds a credential.
Its name looks like one as a variable's does (case and `_' do not
matter), or looks like a key, an authentication or a session, or its
value is a URL with a password in it."
  (and (stringp entry)
       (string-match "\\`\\([^=]*\\)=\\(.*\\)\\'" entry)
       (let ((name (downcase (replace-regexp-in-string "_" "-" (match-string 1 entry))))
             (value (match-string 2 entry))
             (case-fold-search t))
         (or (harness-snapshot--withheld-name-p name)
             (string-match-p "\\(?:\\`\\|-\\)\\(?:key\\|keys\\|auth\\|dsn\\|pass\\|pw\\|jwt\\|sig\\|session\\|private\\)\\(?:-\\|\\'\\)"
                             name)
             (string-match-p "://[^/@: ]+:[^/@ ]+@" value)))))

(defun harness-snapshot--filter-env (entries)
  "Return ENTRIES, a list of environment strings, with credentials' values withheld."
  (mapcar (lambda (entry)
            (if (harness-snapshot--withheld-env-p entry)
                (concat (car (split-string entry "=")) "=<withheld>")
              entry))
          entries))

;;;; Values as plain data

(defun harness-snapshot--describe (x)
  "Return (KIND . DESCRIPTION) for X, an object data cannot hold.
It names X without calling anything of the user's: a buffer by its
name, a process by its name and status, never by its command line."
  (cond
   ((bufferp x) (cons 'buffer (or (and (buffer-live-p x) (buffer-name x)) "killed")))
   ((markerp x) (cons 'marker (format "%s in %s"
                                      (or (marker-position x) "nowhere")
                                      (or (and (marker-buffer x) (buffer-name (marker-buffer x))) "no buffer"))))
   ((windowp x) (cons 'window (or (and (window-live-p x) (buffer-name (window-buffer x))) "dead")))
   ((framep x) (cons 'frame (if (frame-live-p x) (format "%s" (frame-parameter x 'name)) "dead")))
   ((processp x) (cons 'process (format "%s (%s)" (process-name x) (process-status x))))
   ((overlayp x) (cons 'overlay (if (overlay-buffer x)
                                    (format "%s-%s in %s" (overlay-start x) (overlay-end x)
                                            (buffer-name (overlay-buffer x)))
                                  "deleted")))
   ((subrp x) (cons 'subr (subr-name x)))
   ((obarrayp x) (cons 'obarray ""))
   ((char-table-p x) (cons 'char-table (format "%s" (char-table-subtype x))))
   ((functionp x) (cons 'function (format "%s" (type-of x))))
   (t (cons (type-of x) ""))))

(defconst harness-snapshot--mask "<withheld>"
  "What stands in the copy for a value whose key names a credential.")

(defvar harness-snapshot--masked 0
  "How many values of the copy were withheld for the name of their key.")

(defun harness-snapshot--secret-key-p (key &optional entry)
  "Non-nil when KEY, a symbol or a short string, names a credential.
The value that goes with such a key, in an alist, a plist, a hash table
or the slot of a structure, is withheld from the copy.  A string is a key
only when it opens an ENTRY: a pair or a list of up to three elements,
not any string of a long list, such as `process-environment', whose
entries are looked at one by one."
  (cond ((null key) nil)
        ((eq key t) nil)
        ((symbolp key) (harness-snapshot--withheld-name-p (symbol-name key)))
        ((and entry (stringp key) (< (length key) 48)) (harness-snapshot--withheld-name-p key))))

(defun harness-snapshot--short-entry-p (cell)
  "Non-nil when the list CELL begins is a pair, or a list of at most three."
  (let ((n 0))
    (while (and (consp cell) (< n 4))
      (setq n (1+ n)
            cell (cdr cell)))
    (and (< n 4) (null (cdr-safe cell)))))

(defun harness-snapshot--slot-names (record)
  "Return the slot names of RECORD if it is a structure (slot 0 aside), else nil.
This reads the structure's definition, as data; it calls no accessor."
  (let ((tag (aref record 0)))
    (when (and (symbolp tag) (get tag 'cl--class))
      (condition-case nil
          (mapcar #'car (cdr (cl-struct-slot-info tag)))
        (error nil)))))

(defun harness-snapshot--object (x)
  "Return the placeholder for X, an object data cannot hold."
  (let ((described (harness-snapshot--describe x)))
    (record 'harness-user-object (car described) (copy-sequence (cdr described)))))

(defun harness-snapshot--copy (value chars)
  "Return a plain copy of VALUE that prints in about CHARS characters or fewer.
The answer is (:ok COPY), or (:big ESTIMATE) when VALUE is more than
that or more than `harness-snapshot-walk-nodes' pieces, and then the
walk stops where it was.  A copy shares what VALUE shares and closes
the circles it has; strings have no text properties; every object that
is not a number, symbol, string, cons, vector, record, bool-vector or
hash table is a `harness-user-object'.  Nothing in VALUE is called,
printed or compared by anything the user wrote."
  (let ((seen (make-hash-table :test 'eq))
        (nodes 0)
        (size 0)
        (max-size (* chars 4)))
    (catch 'harness-snapshot--big
      (cl-labels
          ((spend (n)
             (setq nodes (1+ nodes)
                   size (+ size n))
             (when (or (> nodes harness-snapshot-walk-nodes) (> size max-size))
               (throw 'harness-snapshot--big (list :big size))))
           (mask ()
             (cl-incf harness-snapshot--masked)
             (copy-sequence harness-snapshot--mask))
           (copy-cons (x depth)
             (let* ((head (cons nil nil))
                    (tail head)
                    (cell x)
                    (closed nil)
                    (mask-next nil)
                    (mask-end nil))
               (while (and (consp cell) (not closed))
                 (let ((known (gethash cell seen)))
                   (if known
                       (progn (setcdr tail known) (setq closed t))
                     (let ((new (cons nil nil))
                           (masking mask-next))
                       (setq mask-next nil)
                       (puthash cell new seen)
                       (spend 3)
                       ;; The value after a key that names a credential: the next
                       ;; element of a plist or a list, the end of a pair.
                       (if masking
                           ;; The value itself is not a key, whatever it says.
                           (setcar new (mask))
                         (setcar new (copy (car cell) (1+ depth)))
                         (when (harness-snapshot--secret-key-p (car cell) (and (eq cell x) (harness-snapshot--short-entry-p x)))
                           (if (consp (cdr cell)) (setq mask-next t) (setq mask-end (cdr cell)))))
                       (setcdr tail new)
                       (setq tail new
                             cell (cdr cell))))))
               (when (and (not closed) cell)
                 (setcdr tail (if (and mask-end (eq cell mask-end)) (mask) (copy cell (1+ depth)))))
               (cdr head)))
           (copy (x depth)
             (cond
              ((or (null x) (eq x t)) x)
              ((integerp x) (spend (if (fixnump x) 6 (ceiling (1+ (logb (abs x))) 3))) x)
              ((floatp x) (spend 10) x)
              ((symbolp x) (spend (+ 2 (length (symbol-name x)))) x)
              ((stringp x) (spend (+ 2 (length x))) (substring-no-properties x))
              ((> depth 100) (spend 40) (record 'harness-user-object 'too-deep ""))
              ((gethash x seen))
              ((consp x) (copy-cons x depth))
              ((vectorp x)
               (let ((new (make-vector (length x) nil)))
                 (puthash x new seen)
                 (dotimes (i (length x))
                   (spend 2)
                   (aset new i (copy (aref x i) (1+ depth))))
                 new))
              ((recordp x)
               (let ((new (make-record 'harness-user-object (1- (length x)) nil))
                     (slots (harness-snapshot--slot-names x)))
                 (puthash x new seen)
                 (dotimes (i (length x))
                   (spend 2)
                   (aset new i (if (and (> i 0) (nth (1- i) slots)
                                        (harness-snapshot--secret-key-p (nth (1- i) slots)))
                                   (mask)
                                 (copy (aref x i) (1+ depth)))))
                 new))
              ((hash-table-p x)
               (let* ((test (hash-table-test x))
                      (new (make-hash-table :test (if (memq test '(eq eql equal)) test 'equal))))
                 (puthash x new seen)
                 (maphash (lambda (k v)
                            (spend 6)
                            (puthash (copy k (1+ depth))
                                     (if (harness-snapshot--secret-key-p k t) (mask) (copy v (1+ depth)))
                                     new))
                          x)
                 new))
              ((bool-vector-p x) (spend (+ 4 (length x))) (copy-sequence x))
              (t (spend 40) (harness-snapshot--object x)))))
        (list :ok (copy value 0))))))

(defun harness-snapshot--unreadable (object _escape)
  "Print OBJECT, which no copy should hold, as a placeholder.
A safety net for `print-unreadable-function': `harness-snapshot--copy'
has replaced every such object already.  It builds the text with `concat'
alone, since printing inside the printer corrupts its output."
  (concat "#s(harness-user-object " (symbol-name (type-of object)) " \"\")"))

(defun harness-snapshot--print (object)
  "Return OBJECT printed for the copy: readable, on one line, plain ASCII."
  (let ((print-length 100000)
        (print-level 200)
        (print-circle t)
        (print-gensym t)
        (print-quoted t)
        (print-escape-newlines t)
        (print-escape-nonascii t)
        (print-escape-multibyte t)
        (print-escape-control-characters t)
        (print-integers-as-characters nil)
        (float-output-format nil)
        (print-unreadable-function #'harness-snapshot--unreadable))
    (prin1-to-string object)))

(defun harness-snapshot--value (name value chars)
  "Return (TEXT . SIZE): VALUE of the variable NAME printed in at most CHARS.
When it does not fit, TEXT is `#s(harness-user-truncated \"NAME\" SIZE)'
and SIZE the length VALUE printed to or, when it was given up before it
was printed, at least that; otherwise SIZE is nil."
  (let ((copy (harness-snapshot--copy value chars)))
    (if (eq (car copy) :big)
        (cons (harness-snapshot--print (record 'harness-user-truncated name (cadr copy)))
              (cadr copy))
      (let ((text (harness-snapshot--print (cadr copy))))
        (if (> (length text) chars)
            (cons (harness-snapshot--print (record 'harness-user-truncated name (length text)))
                  (length text))
          (cons text nil))))))

(defun harness-snapshot--plain (value chars)
  "Return a copy of VALUE as `harness-snapshot--copy' makes it, or nil if too big."
  (let ((copy (harness-snapshot--copy value chars)))
    (and (eq (car copy) :ok) (cadr copy))))

(defun harness-snapshot--alias-p (symbol)
  "Non-nil when the variable SYMBOL is an alias for another."
  (not (eq (condition-case nil (indirect-variable symbol) (error nil)) symbol)))

;;;; The copy being made

(cl-defstruct (harness-snapshot--state (:constructor harness-snapshot--make-state) (:copier nil))
  id seq touched started phase
  buffers          ; the live buffers still to give
  buckets          ; the symbols still to give, in buckets by first letter, sorted
  current          ; the bucket being given, sorted
  (chars 0) (variables 0) (given-buffers 0)
  withheld         ; names of variables left out, newest first
  (withheld-count 0)
  big              ; (NAME . SIZE) of variables too big, newest first
  cut-buffers      ; (NAME FROM TO SIZE) of buffers cut
  left-out         ; names of buffers left out
  (aliases 0) (hidden 0) (not-reached-variables 0) (not-reached-buffers 0))

(defvar harness-snapshot--states nil
  "The copies in the making, newest first.")

(defvar harness-snapshot--counter 0
  "Number of copies begun, to name them.")

(defun harness-snapshot--expire ()
  "Drop the copies not asked for within `harness-snapshot-idle-seconds'."
  (let ((now (float-time)))
    (setq harness-snapshot--states
          (cl-remove-if (lambda (state)
                          (> (- now (harness-snapshot--state-touched state)) harness-snapshot-idle-seconds))
                        harness-snapshot--states))))

(defun harness-snapshot--begin ()
  "Start a copy and return its state."
  (harness-snapshot--expire)
  (setq harness-snapshot--masked 0)
  (setq harness-snapshot--states
        (seq-take harness-snapshot--states (1- harness-snapshot-max-states)))
  (let ((state (harness-snapshot--make-state
                :id (format "snap%d-%04x" (cl-incf harness-snapshot--counter) (random 65536))
                :seq 0 :touched (float-time) :started (float-time) :phase 'header)))
    (push state harness-snapshot--states)
    state))

(defun harness-snapshot--find (cursor)
  "Return the state CURSOR stands for, or signal why there is none.
CURSOR is \"ID:SEQ\" as the last answer gave it; SEQ must be the next
slice in order, so that none is skipped or given twice."
  (unless (and (stringp cursor) (string-match "\\`\\(.+\\):\\([0-9]+\\)\\'" cursor))
    (error "Not a snapshot cursor: %S" cursor))
  (let ((state (cl-find (match-string 1 cursor) harness-snapshot--states
                        :key #'harness-snapshot--state-id :test #'equal))
        (seq (string-to-number (match-string 2 cursor))))
    (cond ((null state)
           (error "No snapshot %s is in the making here (it may have been idle for more than %d seconds)"
                  (match-string 1 cursor) harness-snapshot-idle-seconds))
          ((/= seq (harness-snapshot--state-seq state))
           (error "Snapshot %s is at slice %d, not %d"
                  (harness-snapshot--state-id state) (harness-snapshot--state-seq state) seq))
          (t state))))

(defun harness-snapshot--drop (state)
  "Forget STATE."
  (setq harness-snapshot--states (delq state harness-snapshot--states)))

(defun harness-snapshot--limit (state)
  "Return the characters left in STATE's copy for its variables."
  (- harness-snapshot-max-chars (harness-snapshot--state-chars state)))

;;;; The pieces

(defun harness-snapshot--header ()
  "Return the first form of a copy."
  (harness-snapshot--print
   (list 'snapshot
         :version harness-snapshot-version
         :time (float-time)
         :emacs-version emacs-version
         :system-type system-type
         :system-configuration system-configuration
         :features (harness-snapshot--plain (seq-take features 4000) 100000))))

(defun harness-snapshot--live-buffers (state)
  "Return the buffers a copy holds, and count what it leaves out in STATE.
Hidden buffers (the name starts with a space) are left out and counted,
those named for credentials are left out and named, and at most
`harness-snapshot-max-buffers' are kept, the most recently used first."
  (let (kept)
    (dolist (buffer (buffer-list))
      (let ((name (buffer-name buffer)))
        (cond
         ((or (null name) (string-prefix-p " " name))
          (cl-incf (harness-snapshot--state-hidden state)))
         ((harness-snapshot--withheld-buffer-p buffer)
          (push name (harness-snapshot--state-left-out state)))
         (t (push buffer kept)))))
    (setq kept (nreverse kept))
    (when (> (length kept) harness-snapshot-max-buffers)
      (setf (harness-snapshot--state-not-reached-buffers state)
            (- (length kept) harness-snapshot-max-buffers)
            kept (seq-take kept harness-snapshot-max-buffers)))
    kept))

(defun harness-snapshot--locals (buffer)
  "Return (TEXT . CUT): the local variables of BUFFER, printed as pairs.
TEXT is the inside of a list; CUT is the number of variables kept out of
it because the buffer has more than the copy holds of them."
  (let ((out nil) (chars 0) (count 0) (cut 0))
    (dolist (entry (buffer-local-variables buffer))
      (when (and (consp entry) (symbolp (car entry)))
        (let ((name (symbol-name (car entry))))
          (cond
           ((or (harness-snapshot--withheld-name-p name)
                (memq (car entry) '(buffer-file-name default-directory major-mode))
                (harness-snapshot--alias-p (car entry))))
           ((or (>= count harness-snapshot-locals-count) (>= chars harness-snapshot-locals-chars))
            (cl-incf cut))
           (t
            (let ((pair (concat "(" (harness-snapshot--print (car entry)) " . "
                                (car (harness-snapshot--value name (cdr entry)
                                                              harness-snapshot-local-chars))
                                ")")))
              (push pair out)
              (cl-incf chars (length pair))
              (cl-incf count)))))))
    (cons (string-join (nreverse out) " ") cut)))

(defun harness-snapshot--buffer-form (buffer state)
  "Return the form for BUFFER, noting in STATE what is cut."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (let* ((size (buffer-size))
             (limit harness-snapshot-buffer-chars)
             (point (point))
             (from (if (<= size limit)
                       (point-min)
                     (max (point-min) (min (- point (/ limit 2)) (- (point-max) limit)))))
             (to (min (point-max) (+ from limit)))
             (locals (harness-snapshot--locals buffer)))
        (when (< (- to from) size)
          (push (list (buffer-name) from to size) (harness-snapshot--state-cut-buffers state)))
        (concat "(b :name " (harness-snapshot--print (buffer-name))
                " :mode " (harness-snapshot--print major-mode)
                " :file " (harness-snapshot--print buffer-file-name)
                " :directory " (harness-snapshot--print (expand-file-name default-directory))
                " :point " (number-to-string point)
                " :modified " (if (buffer-modified-p) "t" "nil")
                " :size " (number-to-string size)
                " :text-from " (number-to-string from)
                " :text-to " (number-to-string to)
                " :locals (" (car locals) ")"
                " :locals-cut " (number-to-string (cdr locals))
                " :text " (harness-snapshot--print (buffer-substring-no-properties from to))
                ")\n")))))

(defun harness-snapshot--collect (state)
  "List the symbols that have a value into STATE's buckets, sorted by name."
  (let ((table (make-hash-table :test 'eql)))
    (mapatoms
     (lambda (symbol)
       (when (and (default-boundp symbol)
                  (not (keywordp symbol))
                  (not (memq symbol '(nil t))))
         (let ((name (symbol-name symbol)))
           (push (cons name symbol)
                 (gethash (if (zerop (length name)) 0 (aref name 0)) table))))))
    (let (keys)
      (maphash (lambda (key _) (push key keys)) table)
      (setf (harness-snapshot--state-buckets state)
            (mapcar (lambda (key) (gethash key table)) (sort keys #'<))))))

(defun harness-snapshot--variable-form (name symbol state)
  "Return the form for the variable SYMBOL, named NAME, or nil if it has none.
STATE counts what is left out."
  (cond
   ((harness-snapshot--alias-p symbol)
    (cl-incf (harness-snapshot--state-aliases state))
    nil)
   ((harness-snapshot--withheld-name-p name)
    (cl-incf (harness-snapshot--state-withheld-count state))
    (when (< (length (harness-snapshot--state-withheld state)) harness-snapshot-withheld-listed)
      (push name (harness-snapshot--state-withheld state)))
    nil)
   (t
    (let* ((value (default-value symbol))
           (value (if (memq symbol '(process-environment initial-environment))
                      (and (proper-list-p value) (harness-snapshot--filter-env value))
                    value))
           (printed (harness-snapshot--value name value harness-snapshot-variable-chars)))
      (when (cdr printed)
        (push (cons name (cdr printed)) (harness-snapshot--state-big state)))
      (concat "(v " (harness-snapshot--print symbol) " " (car printed) ")\n")))))

(defun harness-snapshot--manifest (state)
  "Return the last form of STATE's copy: what is in it and what is not."
  (harness-snapshot--print
   (list 'manifest
         :version harness-snapshot-version
         :variables (harness-snapshot--state-variables state)
         :buffers (harness-snapshot--state-given-buffers state)
         :chars (harness-snapshot--state-chars state)
         :elapsed (- (float-time) (harness-snapshot--state-started state))
         :withheld-variables (sort (copy-sequence (harness-snapshot--state-withheld state)) #'string<)
         :withheld-count (harness-snapshot--state-withheld-count state)
         :too-big (reverse (harness-snapshot--state-big state))
         :masked-values harness-snapshot--masked
         :aliases (harness-snapshot--state-aliases state)
         :left-out-buffers (reverse (harness-snapshot--state-left-out state))
         :hidden-buffers (harness-snapshot--state-hidden state)
         :cut-buffers (reverse (harness-snapshot--state-cut-buffers state))
         :not-reached (list :variables (harness-snapshot--state-not-reached-variables state)
                            :buffers (harness-snapshot--state-not-reached-buffers state))
         :limits (list :variable-chars harness-snapshot-variable-chars
                       :buffer-chars harness-snapshot-buffer-chars
                       :max-buffers harness-snapshot-max-buffers
                       :max-chars harness-snapshot-max-chars))))

(defun harness-snapshot--step (state)
  "Give the next piece of STATE's copy: a string, possibly empty, or nil when done.
It advances STATE one item: a form for the header, a buffer, a
variable, or the manifest, or the bookkeeping between them."
  (pcase (harness-snapshot--state-phase state)
    ('header
     (setf (harness-snapshot--state-buffers state) (harness-snapshot--live-buffers state)
           (harness-snapshot--state-phase state) 'buffers)
     (concat (harness-snapshot--header) "\n"))
    ('buffers
     (let ((buffer (pop (harness-snapshot--state-buffers state))))
       (cond
        ((null buffer)
         (setf (harness-snapshot--state-phase state) 'collect)
         "")
        ((not (buffer-live-p buffer)) "")
        ((> (+ (harness-snapshot--state-chars state)
               (min (buffer-size buffer) harness-snapshot-buffer-chars) 4000)
            (min harness-snapshot-buffers-chars harness-snapshot-max-chars))
         (cl-incf (harness-snapshot--state-not-reached-buffers state))
         "")
        (t (cl-incf (harness-snapshot--state-given-buffers state))
           (harness-snapshot--buffer-form buffer state)))))
    ('collect
     (harness-snapshot--collect state)
     (setf (harness-snapshot--state-phase state) 'variables)
     "")
    ('variables
     (cond
      ((<= (harness-snapshot--limit state) harness-snapshot-variable-chars)
       (let ((rest (+ (length (harness-snapshot--state-current state))
                      (cl-loop for bucket in (harness-snapshot--state-buckets state) sum (length bucket)))))
         (setf (harness-snapshot--state-not-reached-variables state) rest
               (harness-snapshot--state-current state) nil
               (harness-snapshot--state-buckets state) nil
               (harness-snapshot--state-phase state) 'manifest))
       "")
      ((harness-snapshot--state-current state)
       (let* ((entry (pop (harness-snapshot--state-current state)))
              (form (harness-snapshot--variable-form (car entry) (cdr entry) state)))
         (when form (cl-incf (harness-snapshot--state-variables state)))
         (or form "")))
      ((harness-snapshot--state-buckets state)
       (setf (harness-snapshot--state-current state)
             (sort (pop (harness-snapshot--state-buckets state))
                   (lambda (a b) (string< (car a) (car b)))))
       "")
      (t (setf (harness-snapshot--state-phase state) 'manifest) "")))
    ('manifest
     (setf (harness-snapshot--state-phase state) 'done)
     (concat (harness-snapshot--manifest state) "\n"))
    (_ nil)))

;;;; The request

(defun harness-snapshot--number (value default low high)
  "Return the number VALUE, kept within LOW and HIGH, or DEFAULT if it is none."
  (if (numberp value) (max low (min high value)) default))

(defun harness-snapshot-slice (params)
  "Give the next slice of a copy of this Emacs: what the `snapshot' request answers.
PARAMS may hold `:cursor' (what the last answer gave; none to begin a
copy), `:seconds' and `:maxChars' (how long to work and how much to give,
within limits) and `:release' (to drop a copy that is not wanted any
more).  The answer is (:chunk TEXT :next CURSOR :done DONE ...): TEXT is
forms to be read, CURSOR is nil when DONE, and `:variables', `:buffers'
and `:chars' say how far the copy has come."
  (harness-snapshot--expire)
  (let ((cursor (plist-get params :cursor)))
    (if (and (plist-get params :release) (not (eq (plist-get params :release) :false)))
        (let ((state (and cursor (ignore-errors (harness-snapshot--find cursor)))))
          (when state (harness-snapshot--drop state))
          (list :chunk "" :next nil :done t :released t))
      (let* ((state (if cursor (harness-snapshot--find cursor) (harness-snapshot--begin)))
             (seconds (harness-snapshot--number (plist-get params :seconds)
                                                harness-snapshot-slice-seconds 0.001 0.25))
             (limit (harness-snapshot--number (plist-get params :maxChars)
                                              harness-snapshot-slice-chars 1000 (* 1024 1024)))
             (deadline (+ (float-time) seconds))
             (chunks nil)
             (length 0))
        (setf (harness-snapshot--state-touched state) (float-time))
        (condition-case err
            (let (piece)
              (while (and (< length limit)
                          (or (null chunks) (< (float-time) deadline))
                          (setq piece (harness-snapshot--step state)))
                (push piece chunks)
                (cl-incf length (length piece))
                (cl-incf (harness-snapshot--state-chars state) (length piece))))
          (error (harness-snapshot--drop state)
                 (signal (car err) (cdr err))))
        (let ((done (eq (harness-snapshot--state-phase state) 'done)))
          (cl-incf (harness-snapshot--state-seq state))
          (when done (harness-snapshot--drop state))
          (list :chunk (apply #'concat (nreverse chunks))
                :next (and (not done)
                           (format "%s:%d" (harness-snapshot--state-id state)
                                   (harness-snapshot--state-seq state)))
                :done (if done t :false)
                :variables (harness-snapshot--state-variables state)
                :buffers (harness-snapshot--state-given-buffers state)
                :chars (harness-snapshot--state-chars state)))))))

(provide 'harness-snapshot)
;;; harness-snapshot.el ends here
