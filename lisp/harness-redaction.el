;;; harness-redaction.el --- Find secrets and take them out of stored text  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The text the harness keeps -- node logs, the search index, the
;; conversation logs of a provider's CLI, buffers -- has to be cleaned of
;; a secret that got into it, and the secret must not pass through the
;; session that does the cleaning.  This library is the part that knows
;; how to name a secret without holding it, find it, and take it out of
;; text.  What to clean and when is for the modules that use it
;; (harness-secrets.el, harness-redact.el); both sides of the process
;; split load it.
;;
;; A secret is a plist (:value V :label L :fingerprint F :source S).  It
;; lives in memory only: it is never stored, logged, emitted, returned
;; to a model or put in an error message.  F is the first 8 hex digits
;; of the SHA-256 of V, and the placeholder that takes its place in text
;; reads [redacted: L sha256:F].  The label and the fingerprint say
;; which secret was here without giving it away; the library signals
;; errors that name them and never the value, and calls nothing that
;; logs.
;;
;; A reference names a secret by where it can be read, so that the value
;; never has to appear in a call or a command line (`harness-redaction-resolve'):
;;
;;   (:file PATH :json-path P [:label L])    a string in a JSON file; an
;;                                           object or array selected yields
;;                                           every string under it
;;   (:file PATH :regexp RE [:label L])      group 1 of each match in a file
;;   (:env NAME [:label L])                  an environment variable
;;   (:literal STRING [:label L])            a value typed by the user
;;   (:command STRING [:label L])            the output of a command
;;
;; `harness-redaction-shape' shows the keys and types of a JSON file, never
;; its values, so that a path into it can be written without reading it.
;;
;; Text is cleaned by replacing the secret wherever it can be spelled.
;; JSON stores a string with escapes -- a quote as \", and some writers
;; escape "/" as \/ -- so each secret has needles (`harness-redaction-needles'):
;; its value as it is, as JSON escapes it, and with "/" escaped too.
;; A match of an escaped needle is replaced by the placeholder escaped
;; the same way (`harness-redaction-pairs').  Text is scanned once, from
;; left to right, taking the longest needle that starts at a position
;; and going on after it: a placeholder is never searched, and a
;; position never counts twice.
;;
;; The functions work on what they are given:
;;
;; - strings and Lisp values (`harness-redaction-string', `-value'): the
;;   decoded text, so the raw values only;
;; - JSON lines and documents (`harness-redaction-jsonl', `-file'): only
;;   the lines that hold a needle are parsed; every other line is kept
;;   byte for byte.  A line is parsed in the style of the harness's own
;;   logs or of a foreign writer's (the style decides how JSON turns into
;;   Lisp and back); a line that does not parse is cleaned as text;
;; - files (`harness-redaction-file', `-file-count', `-rewrite-file'): any
;;   file can be counted, binary ones included, in bytes and in chunks;
;;   text is rewritten atomically, keeping the file's modes;
;; - buffers (`harness-redaction-buffer'), read-only ones included.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'harness-core)
(require 'harness-util)

(defcustom harness-redaction-min-length 8
  "Shortest value, in characters, that is treated as a secret.
A reference that selects a shorter value skips it: a word such as
\"true\" or \"prod\" would be taken out of everything the harness keeps,
and the placeholder would say nothing.  When every value a reference
selects is shorter, resolving it signals an error instead."
  :type 'natnum
  :group 'harness)

(defvar harness-redaction--chunk-size (* 8 1024 1024)
  "Bytes of a file that `harness-redaction-file-count' reads at a time.
It reads this many plus the length of its longest needle less one, so a
needle that straddles two reads is seen whole.  A variable so that
tests can shrink it.")

(define-error 'harness-redaction-changed
  "A file changed while it was being redacted" 'harness-error)

(defconst harness-redaction--shape-limit 1000
  "Most entries `harness-redaction-shape' returns.")

(defconst harness-redaction--label-limit 80
  "Most characters of a label.")

(defconst harness-redaction--depth-limit 100
  "Deepest nesting that `harness-redaction-value' looks into.")

(defconst harness-redaction--binary-probe 8192
  "Bytes at the start of a file that are checked for a NUL byte.")

(defconst harness-redaction--default-label "secret"
  "Label of a secret whose reference gives none and names none.")

(defun harness-redaction--fail (fmt &rest args)
  "Signal a `harness-error' with the message FMT formats with ARGS.
Callers pass labels, fingerprints and paths, never a secret's value."
  (signal 'harness-error (list (apply #'format fmt args))))

;;;; Secrets

(defun harness-redaction-fingerprint (value)
  "Return the first 8 hex digits of the SHA-256 of VALUE, a string.
The digest is of VALUE as UTF-8 bytes."
  (substring (secure-hash 'sha256 (encode-coding-string value 'utf-8)) 0 8))

(defun harness-redaction--label (label)
  "Return LABEL as one that can stand in a placeholder.
Control characters, newlines among them, become spaces and \"]\" becomes
\")\", so a placeholder ends at its closing bracket and stays on one
line.  At most `harness-redaction--label-limit' characters are kept.  A
label that is nil or comes out empty is `harness-redaction--default-label'."
  (let* ((text (cond ((stringp label) label)
                     (label (format "%s" label))
                     (t "")))
         (text (string-trim
                (replace-regexp-in-string
                 "]" ")" (replace-regexp-in-string "[[:cntrl:]]+" " " text) t t))))
    (when (> (length text) harness-redaction--label-limit)
      (setq text (string-trim-right (substring text 0 harness-redaction--label-limit))))
    (if (string-empty-p text) harness-redaction--default-label text)))

(defun harness-redaction-secret (value label &optional source)
  "Return the secret VALUE, named LABEL, found in SOURCE.
SOURCE is a description of where it was read (see
`harness-redaction-describe-source'), or nil.  LABEL is made safe for a
placeholder and the fingerprint is worked out here."
  (list :value value :label (harness-redaction--label label)
        :fingerprint (harness-redaction-fingerprint value) :source source))

(defun harness-redaction-placeholder (secret)
  "Return the text that stands in the place of SECRET in redacted text.
It reads [redacted: LABEL sha256:FINGERPRINT], with the label and the
fingerprint of SECRET, a plist; the fingerprint is worked out from the
value when SECRET has none."
  (format "[redacted: %s sha256:%s]"
          (harness-redaction--label (plist-get secret :label))
          (or (plist-get secret :fingerprint)
              (harness-redaction-fingerprint (plist-get secret :value)))))

;;;; References

(defun harness-redaction--arg (ref key)
  "Return the value of KEY in REF, a reference.
An underscore may spell the hyphen of KEY (`:json_path' for
`:json-path'), as the input of a tool call does."
  (let ((alt (intern (string-replace "-" "_" (symbol-name key)))))
    (or (plist-get ref key)
        (and (not (eq alt key)) (plist-get ref alt)))))

(defun harness-redaction-describe-source (ref)
  "Describe where REF, a reference, reads its secret, without giving it.
The description names a file and the path or regexp into it, or an
environment variable; a value typed by the user and a command's output
are named as that, never with the value or the command."
  (let ((file (plist-get ref :file)))
    (cond
     ((stringp file)
      (let ((path (abbreviate-file-name (expand-file-name file)))
            (json-path (harness-redaction--arg ref :json-path))
            (regexp (plist-get ref :regexp)))
        (cond ((stringp json-path) (format "file %s, JSON path %s" path json-path))
              ((stringp regexp) (format "file %s, regexp %s" path regexp))
              (t (format "file %s" path)))))
     ((stringp (plist-get ref :env))
      (format "environment variable %s" (plist-get ref :env)))
     ((plist-member ref :literal) "typed by the user")
     ((plist-member ref :command) "command output")
     (t "unknown source"))))

;;;; JSON paths

(defun harness-redaction--path-error (path why)
  "Signal that the JSON PATH is invalid, for the reason WHY."
  (harness-redaction--fail "Invalid JSON path %S: %s" path why))

(defun harness-redaction--path-word (word)
  "Return the segment the bare WORD of a JSON path stands for.
`*' is the wildcard and a run of digits is an array index."
  (cond ((string= word "*") '*)
        ((string-match-p "\\`[0-9]+\\'" word) (string-to-number word))
        (t word)))

(defun harness-redaction--path-bracket (path start)
  "Parse the bracketed segment that begins at START in the JSON PATH.
Return (SEGMENT . NEXT), NEXT being the index after the closing bracket.
A bracket holds a quoted key, `*' or an index."
  (let* ((n (length path))
         (i (1+ start)))
    (while (and (< i n) (memq (aref path i) '(?\s ?\t))) (setq i (1+ i)))
    (when (>= i n) (harness-redaction--path-error path "unterminated ["))
    (let ((quote-char (aref path i)))
      (if (memq quote-char '(?\" ?'))
          (let ((chars nil) (closed nil))
            (setq i (1+ i))
            (while (and (< i n) (not closed))
              (let ((c (aref path i)))
                (cond ((eq c ?\\)
                       (when (>= (1+ i) n) (harness-redaction--path-error path "unterminated quote"))
                       (push (aref path (1+ i)) chars)
                       (setq i (+ i 2)))
                      ((eq c quote-char) (setq closed t i (1+ i)))
                      (t (push c chars) (setq i (1+ i))))))
            (unless closed (harness-redaction--path-error path "unterminated quote"))
            (while (and (< i n) (memq (aref path i) '(?\s ?\t))) (setq i (1+ i)))
            (unless (and (< i n) (eq (aref path i) ?\]))
              (harness-redaction--path-error path "expected ] after a quoted key"))
            (cons (apply #'string (nreverse chars)) (1+ i)))
        (let ((close (string-search "]" path i)))
          (unless close (harness-redaction--path-error path "unterminated ["))
          (let ((word (string-trim (substring path i close))))
            (when (string-empty-p word) (harness-redaction--path-error path "empty brackets"))
            (let ((segment (harness-redaction--path-word word)))
              (when (stringp segment)
                (harness-redaction--path-error path "a key in brackets must be quoted"))
              (cons segment (1+ close)))))))))

(defun harness-redaction-json-path-parse (string)
  "Return the segments of the JSON path STRING.
The path is dot-separated segments, with an optional leading \".\" or
\"$.\" (a lone \"$\" is the root).  A segment is a key, a non-negative
integer (an array index; for an object, the key of that number), \"*\"
\(every key or element) or a bracketed key, [\"a.b\"], for a key that has
dots, brackets or spaces or only digits.  A bracket may follow a segment
without a dot, as in a[0].b, and holds an index or \"*\" as well.  The
segments come as strings, integers and the symbol `*'; the root has none.
Signal a `harness-error' when STRING is not a path."
  (unless (stringp string)
    (harness-redaction--fail "A JSON path is a string"))
  (let* ((text (string-trim string))
         (n (length text))
         (i 0)
         (expect 'start)
         (segments nil))
    ;; A $ is the root only alone or before . or [: $schema is a key.
    (when (and (< i n) (eq (aref text i) ?$)
               (or (= n 1) (memq (aref text 1) '(?. ?\[))))
      (setq i 1))
    (when (and (< i n) (eq (aref text i) ?.))
      (setq i (1+ i)
            expect (if (= i n) 'start 'segment)))
    (while (< i n)
      (let ((c (aref text i)))
        (cond
         ((eq c ?\[)
          (let ((parsed (harness-redaction--path-bracket text i)))
            (push (car parsed) segments)
            (setq i (cdr parsed) expect 'after)))
         ((eq c ?.)
          (unless (eq expect 'after)
            (harness-redaction--path-error string "empty segment"))
          (setq i (1+ i) expect 'segment))
         (t
          (when (eq expect 'after)
            (harness-redaction--path-error string "expected . or [ after a segment"))
          (let* ((end (or (string-match "[.[]" text i) n))
                 (word (string-trim (substring text i end))))
            (when (string-empty-p word)
              (harness-redaction--path-error string "empty segment"))
            (when (string-search "]" word)
              (harness-redaction--path-error string "unbalanced ]"))
            (push (harness-redaction--path-word word) segments)
            (setq i end expect 'after))))))
    (when (eq expect 'segment)
      (harness-redaction--path-error string "the path ends with a dot"))
    (nreverse segments)))

(defun harness-redaction--bare-key-p (key)
  "Non-nil when the object key KEY can stand in a JSON path without brackets."
  (and (> (length key) 0)
       (not (member key '("*" "$")))
       (not (string-match-p "\\`[0-9]+\\'" key))
       (cl-every (lambda (c) (and (not (memq c '(?. ?\[ ?\] ?\s ?\t ?\n ?\r)))
                                  (>= c 32) (/= c 127)))
                 key)))

(defun harness-redaction--path-text (segments)
  "Return SEGMENTS, a list of keys and indices, as a JSON path to parse again.
The root, no segments, is \"$\"."
  (if (null segments)
      "$"
    (let ((out ""))
      (dolist (s segments)
        (setq out
              (cond ((integerp s)
                     (concat out (if (string-empty-p out) "" ".") (number-to-string s)))
                    ((harness-redaction--bare-key-p s)
                     (concat out (if (string-empty-p out) "" ".") s))
                    (t (concat out "[\""
                               (string-replace "\"" "\\\"" (string-replace "\\" "\\\\" s))
                               "\"]")))))
      out)))

(defun harness-redaction--join (segments)
  "Return SEGMENTS joined with dots, as a label reads a path."
  (mapconcat (lambda (s) (format "%s" s)) segments "."))

;;;; Reading JSON

(defun harness-redaction--existing-file (file)
  "Return FILE as an absolute name, or signal when it is no readable file."
  (unless (and (stringp file) (not (string-empty-p file)))
    (harness-redaction--fail "A file name is a non-empty string"))
  (let ((path (expand-file-name file)))
    (cond ((file-directory-p path)
           (harness-redaction--fail "%s is a directory" (abbreviate-file-name path)))
          ((not (file-readable-p path))
           (harness-redaction--fail "Cannot read %s" (abbreviate-file-name path))))
    path))

(defun harness-redaction--read-json (path)
  "Return the JSON document in the file PATH, parsed.
Objects are alists, arrays vectors, null `:null' and false `:false'.
The error for a file that is not JSON says so and nothing of the file."
  (let ((text (harness-read-file path)))
    (condition-case nil
        (json-parse-string text :object-type 'alist :array-type 'array
                           :null-object :null :false-object :false)
      (error (harness-redaction--fail "%s is not valid JSON" (abbreviate-file-name path))))))

(defun harness-redaction--object-p (node)
  "Non-nil when NODE, a parsed JSON value, is an object: an alist, or nil for {}."
  (and (listp node) (or (null node) (consp (car node)))))

(defun harness-redaction--json-type (node)
  "Return the JSON type of the parsed value NODE, as a string."
  (cond ((stringp node) "string")
        ((numberp node) "number")
        ((memq node '(t :false)) "boolean")
        ((eq node :null) "null")
        ((vectorp node) "array")
        (t "object")))

(defun harness-redaction--children (path node)
  "Return the children of NODE, which is at PATH, as ((PATH . CHILD)...).
PATH is a list of keys and indices; a child's is PATH and its own."
  (cond ((vectorp node)
         (cl-loop for i from 0 below (length node)
                  collect (cons (append path (list i)) (aref node i))))
        ((harness-redaction--object-p node)
         (mapcar (lambda (e) (cons (append path (list (symbol-name (car e)))) (cdr e)))
                 node))))

(defun harness-redaction--select (doc segments)
  "Return the nodes of DOC that SEGMENTS select, as ((PATH . NODE)...).
PATH is the keys and indices taken from the root.  A key selects the
members of an object that have it, an integer an element of an array (or
the key of that number), and `*' every member or element."
  (let ((current (list (cons nil doc))))
    (dolist (segment segments)
      (let (next)
        (dolist (entry current)
          (let ((path (car entry)) (node (cdr entry)))
            (cond
             ((eq segment '*)
              (dolist (child (harness-redaction--children path node)) (push child next)))
             ((and (integerp segment) (vectorp node))
              (when (< segment (length node))
                (push (cons (append path (list segment)) (aref node segment)) next)))
             ((and (or (stringp segment) (integerp segment))
                   (harness-redaction--object-p node))
              (let ((key (if (integerp segment) (number-to-string segment) segment)))
                (dolist (e node)
                  (when (equal (symbol-name (car e)) key)
                    (push (cons (append path (list key)) (cdr e)) next))))))))
        (setq current (nreverse next))))
    current))

(defun harness-redaction--string-leaves (path node)
  "Return the strings under NODE, which is at PATH, as ((PATH . STRING)...).
NODE is a string itself when it has no children.  The order is depth first."
  (let ((stack (list (cons path node))) out)
    (while stack
      (let* ((entry (pop stack)) (n (cdr entry)))
        (if (stringp n)
            (push (cons (car entry) n) out)
          (dolist (child (reverse (harness-redaction--children (car entry) n)))
            (push child stack)))))
    (nreverse out)))

;;;; Resolving references

(defun harness-redaction--json-candidates (ref)
  "Return the (LABEL . VALUE) candidates of REF, a reference to a JSON path."
  (let* ((path (harness-redaction--existing-file (plist-get ref :file)))
         (spec (harness-redaction--arg ref :json-path))
         (segments (progn
                     (when (string-blank-p spec)
                       (harness-redaction--fail "The JSON path is empty"))
                     (harness-redaction-json-path-parse spec)))
         (label (plist-get ref :label))
         (nodes (harness-redaction--select (harness-redaction--read-json path) segments)))
    (unless nodes
      (harness-redaction--fail "No value at JSON path %s in %s" spec (abbreviate-file-name path)))
    (let ((leaves (apply #'append
                         (mapcar (lambda (n) (harness-redaction--string-leaves (car n) (cdr n)))
                                 nodes))))
      (unless leaves
        (harness-redaction--fail "JSON path %s selects no string in %s"
                                 spec (abbreviate-file-name path)))
      ;; With a label given: one secret has it, several have it and what
      ;; lies below the part of the path before the first wildcard.
      (let ((fixed (or (cl-position '* segments) (length segments)))
            (several (cdr leaves)))
        (mapcar (lambda (leaf)
                  (cons (cond ((null label) (harness-redaction--join (car leaf)))
                              ((not several) label)
                              (t (let ((below (nthcdr fixed (car leaf))))
                                   (if below
                                       (concat label "." (harness-redaction--join below))
                                     label))))
                        (cdr leaf)))
                leaves)))))

(defun harness-redaction--regexp-candidates (ref)
  "Return the (LABEL . VALUE) candidates of REF, a reference to a regexp."
  (let* ((path (harness-redaction--existing-file (plist-get ref :file)))
         (regexp (plist-get ref :regexp))
         (base (or (plist-get ref :label) (file-name-nondirectory path)))
         (values nil) (matched nil) (case-fold-search nil))
    (with-temp-buffer
      (harness-redaction--insert-file path)
      (goto-char (point-min))
      (condition-case err
          (let ((more t))
            (while (and more (re-search-forward regexp nil t))
              (setq matched t)
              (when (match-beginning 1)
                (cl-pushnew (match-string-no-properties 1) values :test #'equal))
              ;; A match of nothing must not be found again where it is.
              (when (= (match-beginning 0) (match-end 0))
                (if (eobp) (setq more nil) (forward-char 1)))))
        (invalid-regexp
         (harness-redaction--fail "Invalid regexp: %s" (cadr err)))))
    (setq values (nreverse values))
    (cond ((not matched)
           (harness-redaction--fail "The regexp matches nothing in %s" (abbreviate-file-name path)))
          ((null values)
           (harness-redaction--fail "The regexp has no group 1 that matched in %s"
                                    (abbreviate-file-name path))))
    (let ((i 0))
      (mapcar (lambda (value)
                (cons (if (cdr values) (format "%s.%d" base (cl-incf i)) base) value))
              values))))

(defun harness-redaction--env-candidates (ref)
  "Return the (LABEL . VALUE) candidates of REF, a reference to a variable."
  (let* ((name (plist-get ref :env))
         (value (getenv name)))
    (if (and value (not (string-empty-p value)))
        (list (cons (or (plist-get ref :label) name) value))
      (harness-redaction--fail "Environment variable %s is not set" name))))

(defun harness-redaction--run-command (command)
  "Run the shell COMMAND and return its output without trailing newlines.
It runs where Emacs runs, with no input.  Its output, and its errors,
are never shown: a failure says only that the command failed."
  (with-temp-buffer
    (let* ((default-directory (if (and (not (file-remote-p default-directory))
                                       (file-directory-p default-directory))
                                  default-directory
                                (expand-file-name "~/")))
           (coding-system-for-read 'utf-8-unix)
           (status (condition-case nil
                       (process-file shell-file-name nil (list t nil) nil
                                     shell-command-switch command)
                     (error nil))))
      (unless (eq status 0)
        (harness-redaction--fail "The command failed (%s)"
                                 (if (integerp status)
                                     (format "exit status %d" status)
                                   "it could not be run")))
      (replace-regexp-in-string "[\r\n]+\\'" "" (buffer-string)))))

(defun harness-redaction--command-candidates (ref)
  "Return the (LABEL . VALUE) candidates of REF, a reference to a command."
  (let ((value (harness-redaction--run-command (plist-get ref :command))))
    (if (string-empty-p value)
        (harness-redaction--fail "The command printed nothing")
      (list (cons (or (plist-get ref :label) harness-redaction--default-label) value)))))

(defun harness-redaction-resolve (ref)
  "Resolve REF, a reference, to the secrets it names.
REF is one of (:file PATH :json-path P), (:file PATH :regexp RE), (:env
NAME), (:literal STRING) or (:command STRING), each with an optional
:label.  The value is read now and kept in memory only.

A JSON path selects strings: a string, or every string under an object
or an array.  Each is a secret labelled with its path from the root, or,
with a :label, a single one is labelled so and several are labelled
\"LABEL.\" and the path below the selection.  Group 1 of each match of a
regexp is a secret, labelled by the file (or the :label) and a number
when there are several.  A value shorter than `harness-redaction-min-length'
is skipped.

Return (:secrets SECRETS :skipped N :source DESCRIPTION).  SECRETS are
plists (:value :label :fingerprint :source), without duplicates, the
longest value first; N counts the values skipped for being short.
Signal a `harness-error' when no value is left to redact: the file is
missing or holds nothing there, the variable is unset, the command
fails, or every value is short.  The message names labels and
fingerprints, never a value."
  (unless (and ref (listp ref))
    (harness-redaction--fail "A secret reference is a plist"))
  (let* ((candidates
          (cond
           ((stringp (plist-get ref :file))
            (cond ((harness-redaction--arg ref :json-path)
                   (harness-redaction--json-candidates ref))
                  ((stringp (plist-get ref :regexp))
                   (harness-redaction--regexp-candidates ref))
                  (t (harness-redaction--fail "A file reference needs a :json-path or a :regexp"))))
           ((stringp (plist-get ref :env)) (harness-redaction--env-candidates ref))
           ((stringp (plist-get ref :literal))
            (list (cons (or (plist-get ref :label) harness-redaction--default-label)
                        (plist-get ref :literal))))
           ((stringp (plist-get ref :command)) (harness-redaction--command-candidates ref))
           (t (harness-redaction--fail
               "A secret reference needs :file with :json-path or :regexp, :env, :literal or :command"))))
         (source (harness-redaction-describe-source ref))
         (seen (make-hash-table :test 'equal))
         (usable nil) (skipped nil))
    (dolist (c candidates)
      (let ((value (cdr c)))
        (when (and (stringp value) (not (string-empty-p value)) (not (gethash value seen)))
          (puthash value t seen)
          (if (< (length value) harness-redaction-min-length)
              (push (harness-redaction-secret value (car c)) skipped)
            (push (harness-redaction-secret value (car c)) usable)))))
    (setq usable (nreverse usable) skipped (nreverse skipped))
    (unless usable
      (if (null skipped)
          (harness-redaction--fail "%s holds no value to redact" source)
        (harness-redaction--fail
         "Nothing to redact for %s: %s%s %s shorter than %d characters (harness-redaction-min-length)"
         source
         (mapconcat (lambda (s) (format "%s (sha256:%s)" (plist-get s :label) (plist-get s :fingerprint)))
                    (take 5 skipped) ", ")
         (if (> (length skipped) 5) (format " and %d more" (- (length skipped) 5)) "")
         (if (cdr skipped) "are" "is")
         harness-redaction-min-length)))
    ;; The description names a regexp or a path, which could hold a value
    ;; typed in the wrong place: it never leaves with one.
    (let ((source (car (harness-redaction-string source usable))))
      (list :secrets (sort (mapcar (lambda (s) (plist-put (copy-sequence s) :source source)) usable)
                           (lambda (a b) (> (length (plist-get a :value))
                                            (length (plist-get b :value)))))
            :skipped (length skipped)
            :source source))))

;;;; Shape

(defun harness-redaction-shape (file &optional json-path)
  "Return the keys and types of the JSON document FILE, never its values.
The result lists (:path PATH :type TYPE) for every node under the nodes
JSON-PATH selects (the whole document by default), depth first,
starting with the selected node itself.  PATH is the path from the
root, in the syntax `harness-redaction-json-path-parse' reads (\"$\" for
the root), and TYPE is \"object\", \"array\", \"string\", \"number\",
\"boolean\" or \"null\".  There are at most `harness-redaction--shape-limit'
entries; when the document has more, a last entry, (:truncated t), says
so.  A string's length is not given either."
  (let* ((path (harness-redaction--existing-file file))
         (segments (harness-redaction-json-path-parse (or json-path "")))
         (nodes (harness-redaction--select (harness-redaction--read-json path) segments))
         (stack (copy-sequence nodes))
         (count 0) (truncated nil) (out nil))
    (unless nodes
      (harness-redaction--fail "No value at JSON path %s in %s"
                               json-path (abbreviate-file-name path)))
    (while (and stack (not truncated))
      (let* ((entry (pop stack)) (node (cdr entry)))
        (if (>= count harness-redaction--shape-limit)
            (setq truncated t)
          (push (list :path (harness-redaction--path-text (car entry))
                      :type (harness-redaction--json-type node))
                out)
          (cl-incf count)
          (dolist (child (reverse (harness-redaction--children (car entry) node)))
            (push child stack)))))
    (nreverse (if truncated (cons (list :truncated t) out) out))))

;;;; Needles and replacements

(defun harness-redaction--json-escape (string)
  "Return STRING as JSON writes it between quotes, as text, or nil.
Nil when STRING cannot be encoded as JSON.  The string is written as the
only element of an array, as the JSON writers of Emacs 29 take no
top-level string."
  (condition-case nil
      (let ((json (json-serialize (vector string))))
        (substring (if (multibyte-string-p json) json (decode-coding-string json 'utf-8-unix))
                   2 -2))
    (error nil)))

(defun harness-redaction--sort-pairs (pairs)
  "Return PAIRS, (NEEDLE . REPLACEMENT) conses, with the longest needle first.
The order of needles of one length is kept."
  (sort (copy-sequence pairs)
        (lambda (a b) (> (length (car a)) (length (car b))))))

(defun harness-redaction--secret-pairs (secret)
  "Return the (NEEDLE . REPLACEMENT) pairs of SECRET, one per needle.
The raw value stands for the placeholder; the value as JSON escapes it,
and with its slashes escaped, for the placeholder escaped the same way."
  (let ((value (plist-get secret :value)))
    (when (and (stringp value) (not (string-empty-p value)))
      (let* ((placeholder (harness-redaction-placeholder secret))
             (escaped (harness-redaction--json-escape value))
             (marker (and escaped (harness-redaction--json-escape placeholder)))
             (pairs (list (cons value placeholder)))
             (out nil))
        (when (and escaped marker)
          (setq pairs (append pairs
                              (list (cons escaped marker)
                                    (cons (string-replace "/" "\\/" escaped)
                                          (string-replace "/" "\\/" marker))))))
        (dolist (p pairs)
          (unless (or (string-empty-p (car p)) (assoc (car p) out))
            (push p out)))
        (nreverse out)))))

(defun harness-redaction-needles (secret)
  "Return the strings to look for in stored text to find SECRET.
They are its value; its value as JSON escapes it between quotes (a quote
as a backslash and a quote, a newline as a backslash and an n); and that
with \"/\" escaped as a backslash and a slash, as some writers do.
Duplicates are left out, so a value that needs no escape has one needle."
  (mapcar #'car (harness-redaction--secret-pairs secret)))

(defun harness-redaction-pairs (secrets)
  "Return the (NEEDLE . REPLACEMENT) pairs for SECRETS, longest needle first.
Each needle (`harness-redaction-needles') is paired with what replaces it:
the placeholder for the raw value, and for an escaped needle the
placeholder escaped the same way, so that replacing in JSON text leaves
valid JSON.  A needle two secrets share belongs to the first."
  (let ((seen (make-hash-table :test 'equal))
        (out nil))
    (dolist (secret secrets)
      (dolist (p (harness-redaction--secret-pairs secret))
        (unless (gethash (car p) seen)
          (puthash (car p) t seen)
          (push p out))))
    (harness-redaction--sort-pairs (nreverse out))))

(defun harness-redaction--raw-pairs (secrets)
  "Return (VALUE . PLACEHOLDER) for each of SECRETS, the longest value first.
These are the pairs for decoded text: strings, and the strings of a
parsed document."
  (let ((seen (make-hash-table :test 'equal))
        (out nil))
    (dolist (secret secrets)
      (let ((value (plist-get secret :value)))
        (when (and (stringp value) (not (string-empty-p value)) (not (gethash value seen)))
          (puthash value t seen)
          (push (cons value (harness-redaction-placeholder secret)) out))))
    (harness-redaction--sort-pairs (nreverse out))))

;;;; Finding and replacing

(defun harness-redaction--finder (pairs find from)
  "Return a function that finds the hits of PAIRS in a text one at a time.
PAIRS is a list of (NEEDLE . REPLACEMENT), longest needle first; FIND is
a function of a needle and a position that returns where the first
occurrence of the needle at or after the position starts, or nil; FROM
is the position to start at.  Each call of the function returns the next
hit, (START END . REPLACEMENT), or nil when there is none.  The search
goes from left to right and takes the longest needle that starts at a
position (the first pair, at a tie) and goes on after it, so hits never
overlap.  A call may give a position to skip to, which moves the search
forward to it.  Each needle is searched for once across the text, not
once per hit."
  (let* ((pairs (vconcat pairs))
         (n (length pairs))
         (next (make-vector n nil))
         (pos from))
    (lambda (&optional skip-to)
      (when (and skip-to (> skip-to pos)) (setq pos skip-to))
      (let ((best nil) (best-i nil))
        (dotimes (i n)
          (let ((at (aref next i)))
            (when (or (null at) (and (integerp at) (< at pos)))
              (setq at (or (funcall find (car (aref pairs i)) pos) :none))
              (aset next i at))
            (when (and (integerp at) (or (null best) (< at best)))
              (setq best at best-i i))))
        (when best
          (let ((pair (aref pairs best-i)))
            (setq pos (+ best (length (car pair))))
            (cons best (cons pos (cdr pair)))))))))

(defun harness-redaction--scan (pairs find from)
  "Return all the hits of PAIRS in a text from position FROM on, in order.
FIND is as for `harness-redaction--finder', which does the work."
  (let ((next (harness-redaction--finder pairs find from))
        (hits nil))
    (while-let ((hit (funcall next)))
      (push hit hits))
    (nreverse hits)))

(defun harness-redaction--string-hits (string pairs)
  "Return the hits of PAIRS in STRING; see `harness-redaction--scan'."
  (let ((len (length string)))
    (harness-redaction--scan pairs
                             (lambda (needle pos)
                               (and (<= pos len) (string-search needle string pos)))
                             0)))

(defun harness-redaction--splice (string hits)
  "Return STRING with each of HITS, (START END . REPLACEMENT), replaced."
  (let ((pos 0) (parts nil))
    (dolist (h hits)
      (push (substring string pos (car h)) parts)
      (push (cddr h) parts)
      (setq pos (cadr h)))
    (push (substring string pos) parts)
    (apply #'concat (nreverse parts))))

(defun harness-redaction--buffer-find (needle pos)
  "Return where NEEDLE first occurs in the current buffer at or after POS, or nil.
The search is case sensitive and moves point."
  (let ((case-fold-search nil))
    (goto-char pos)
    (and (search-forward needle nil t) (match-beginning 0))))

(defun harness-redaction--buffer-hits (pairs &optional from)
  "Return the hits of PAIRS in the current buffer, from FROM (the start).
Hit positions are buffer positions.  See `harness-redaction--scan'."
  (save-excursion
    (save-match-data
      (harness-redaction--scan pairs #'harness-redaction--buffer-find (or from (point-min))))))

(defun harness-redaction--replace-hits (hits)
  "Replace each of HITS, (START END . REPLACEMENT), in the current buffer.
The last goes first, so the positions of the others hold.  A
replacement has the text properties of the first character it replaces."
  (save-match-data
    (dolist (h (reverse hits))
      (let ((props (text-properties-at (car h))))
        (set-match-data (list (car h) (cadr h)))
        (replace-match (cddr h) t t)
        (when props
          (set-text-properties (car h) (+ (car h) (length (cddr h))) props))))))

(defun harness-redaction-count (string secrets)
  "Return how many times SECRETS occur in STRING, JSON escapes included.
That is the occurrences of every needle (`harness-redaction-pairs'),
found as `harness-redaction--scan' finds them: the longest first, none
overlapping, so a position that two needles match counts once."
  (length (harness-redaction--string-hits string (harness-redaction-pairs secrets))))

(defun harness-redaction-string (string secrets)
  "Replace the values of SECRETS in STRING by their placeholders.
Return (NEW . COUNT).  NEW is STRING itself when COUNT is 0.  Only the
raw values are looked for: STRING is text, not JSON."
  (let ((hits (harness-redaction--string-hits string (harness-redaction--raw-pairs secrets))))
    (if hits
        (cons (harness-redaction--splice string hits) (length hits))
      (cons string 0))))

;;;; Lisp values

(defun harness-redaction--circular-p (list)
  "Non-nil when LIST, a cons, is circular.  A dotted list is not."
  (let ((slow list) (fast list))
    (catch 'result
      (while t
        (setq fast (cdr-safe fast))
        (unless (consp fast) (throw 'result nil))
        (setq fast (cdr-safe fast))
        (unless (consp fast) (throw 'result nil))
        (setq slow (cdr slow))
        (when (eq slow fast) (throw 'result t))))))

(defun harness-redaction--walk-list (list pairs depth counter)
  "Return LIST, a cons, with its strings redacted by PAIRS.
DEPTH and COUNTER are as for `harness-redaction--walk'.  Unchanged, LIST
is returned as it is; otherwise its cells are new and what did not
change is shared.  A circular list is left alone."
  (if (harness-redaction--circular-p list)
      list
    (let ((cells nil) (changed nil) (tail list))
      (while (consp tail)
        (let* ((old (car tail))
               (new (harness-redaction--walk old pairs (1+ depth) counter)))
          (unless (eq old new) (setq changed t))
          (push new cells))
        (setq tail (cdr tail)))
      (let ((new-tail (if tail (harness-redaction--walk tail pairs (1+ depth) counter) tail)))
        (unless (eq new-tail tail) (setq changed t))
        (if changed
            (nconc (nreverse cells) new-tail)
          list)))))

(defun harness-redaction--walk (obj pairs depth counter)
  "Return OBJ with the strings in it redacted by PAIRS.
COUNTER is a cons whose car counts the replacements.  DEPTH is the
nesting reached; beyond `harness-redaction--depth-limit' OBJ is left
alone."
  (cond
   ((> depth harness-redaction--depth-limit) obj)
   ((stringp obj)
    (let ((hits (harness-redaction--string-hits obj pairs)))
      (if hits
          (progn (cl-incf (car counter) (length hits))
                 (harness-redaction--splice obj hits))
        obj)))
   ;; Not a function: in Emacs 29 a closure is a list.
   ((and (consp obj) (not (functionp obj)))
    (harness-redaction--walk-list obj pairs depth counter))
   ((vectorp obj)
    (let ((copy nil))
      (dotimes (i (length obj))
        (let* ((old (aref obj i))
               (new (harness-redaction--walk old pairs (1+ depth) counter)))
          (unless (eq old new)
            (unless copy (setq copy (copy-sequence obj)))
            (aset copy i new))))
      (or copy obj)))
   (t obj)))

(defun harness-redaction-value (value secrets)
  "Replace the values of SECRETS in the strings of the Lisp object VALUE.
Return (NEW . COUNT).  The walk goes into conses (lists, plists, alists,
dotted pairs) and vectors, and no further: not into records, functions
or hash tables, nor deeper than `harness-redaction--depth-limit'.  It is
copy on write: NEW is VALUE itself when COUNT is 0, and otherwise shares
with VALUE whatever did not change."
  (let* ((pairs (harness-redaction--raw-pairs secrets))
         (counter (list 0))
         (new (if pairs (harness-redaction--walk value pairs 0 counter) value)))
    (cons new (car counter))))

;;;; JSON lines

(defun harness-redaction--parse (text style)
  "Return (OBJECT) for the JSON in TEXT, or nil when STYLE cannot read it.
STYLE is `harness', which reads as `harness-json-parse' does (objects
are plists, arrays lists, null nil), or `foreign' (objects are alists,
arrays vectors, null `:null' and false `:false')."
  (condition-case nil
      (list (if (eq style 'harness)
                (harness-json-parse text)
              (json-parse-string text :object-type 'alist :array-type 'array
                                 :null-object :null :false-object :false)))
    (error nil)))

(defun harness-redaction--serialize (object style)
  "Return OBJECT as JSON text in STYLE, or nil when it cannot be written.
STYLE is as for `harness-redaction--parse'."
  (condition-case nil
      (if (eq style 'harness)
          (harness-json-encode-text object)
        (let ((json (json-serialize object :null-object :null :false-object :false)))
          (if (multibyte-string-p json) json (decode-coding-string json 'utf-8-unix))))
    (error nil)))

(defun harness-redaction--redact-json (text raw-pairs pairs style on-line)
  "Redact TEXT, a line or document of JSON; return (NEW . COUNT) or nil.
The strings of the parsed text are searched for the values of RAW-PAIRS
and the text is written again, when it reads back as the object that was
written: a key twice in one object, say, would not.  Where that finds
nothing, because TEXT is no JSON, or holds the secret in a key, or in a
spelling the strings do not show, or cannot be written again as it
means, TEXT is searched for the needles of PAIRS as it is.  STYLE is how
JSON is read and written (see `harness-redaction-jsonl').  ON-LINE, when
given, is called with the object parsed, the object redacted and the
count, for a text that parsed and changed."
  (let* ((parsed (harness-redaction--parse text style))
         (found nil))
    (when parsed
      (let* ((counter (list 0))
             (new (harness-redaction--walk (car parsed) raw-pairs 0 counter)))
        (when (> (car counter) 0)
          (when-let* ((out (harness-redaction--serialize new style))
                      (again (harness-redaction--parse out style))
                      ((equal (car again) new)))
            (when on-line (funcall on-line (car parsed) new (car counter)))
            (setq found (cons out (car counter)))))))
    (or found
        (let ((hits (harness-redaction--string-hits text pairs)))
          (when hits
            (let ((out (harness-redaction--splice text hits)))
              (when (and parsed on-line)
                (when-let* ((again (harness-redaction--parse out style)))
                  (funcall on-line (car parsed) (car again) (length hits))))
              (cons out (length hits))))))))

(defun harness-redaction--jsonl-buffer (secrets style on-line)
  "Redact SECRETS in the JSON lines of the current buffer.
Return (COUNT LINES CHANGES); the buffer is not changed.  STYLE and
ON-LINE are as for `harness-redaction-jsonl'.  CHANGES lists (START END
NEW), the last line first, for `harness-redaction--apply-changes'.  Only
a line with a needle in it is parsed."
  (let* ((pairs (harness-redaction-pairs secrets))
         (raw-pairs (harness-redaction--raw-pairs secrets))
         (count 0) (lines 0) (changes nil))
    (save-excursion
      (save-match-data
        (let* ((next (harness-redaction--finder pairs #'harness-redaction--buffer-find (point-min)))
               (hit (funcall next)))
          (while hit
            (goto-char (car hit))
            (let* ((beg (pos-bol))
                   (end (pos-eol))
                   (line (buffer-substring-no-properties beg end))
                   (cr (string-suffix-p "\r" line))
                   (body (if cr (substring line 0 -1) line))
                   (result (harness-redaction--redact-json body raw-pairs pairs style on-line)))
              (when result
                (cl-incf count (cdr result))
                (cl-incf lines)
                (push (list beg end (if cr (concat (car result) "\r") (car result))) changes))
              ;; The next line: this one has been dealt with whole.
              (setq hit (funcall next (1+ end))))))))
    (list count lines changes)))

(defun harness-redaction--apply-changes (changes)
  "Make CHANGES, (START END NEW) with the last first, in the current buffer."
  (dolist (c changes)
    (goto-char (nth 0 c))
    (delete-region (nth 0 c) (nth 1 c))
    (insert (nth 2 c))))

(defun harness-redaction-jsonl (text secrets &rest options)
  "Redact SECRETS in TEXT, JSON lines.  Return (NEW-TEXT :count N :lines L).
Only a line that holds a needle (`harness-redaction-needles') is
parsed and written again; every other line is kept byte for byte, and
so is the final newline.  A line that does not parse, or would not mean
the same written again (a key twice in an object, say), gets each needle
replaced by its placeholder as it stands.  N counts the replacements and
L the lines that changed.  OPTIONS:

  :style    `foreign' (the default) reads and writes JSON as another
            program does it (objects as alists, arrays as vectors);
            `harness' as the harness's own logs are read and written
            (`harness-json-parse', `harness-json-encode-text');
  :dry-run  non-nil only counts: NEW-TEXT is TEXT;
  :on-line  a function called with (OLD-OBJECT NEW-OBJECT COUNT) for
            each line that parsed and changed."
  (let ((style (or (plist-get options :style) 'foreign))
        (dry-run (plist-get options :dry-run))
        (on-line (plist-get options :on-line)))
    (unless (memq style '(harness foreign))
      (harness-redaction--fail "Unknown JSON style %S" style))
    (with-temp-buffer
      (insert text)
      (pcase-let* ((`(,count ,lines ,changes) (harness-redaction--jsonl-buffer secrets style on-line))
                   (stats (list :count count :lines lines)))
        (if (or dry-run (null changes))
            (cons text stats)
          (harness-redaction--apply-changes changes)
          (cons (buffer-string) stats))))))

;;;; Files

(defun harness-redaction--insert-file (path)
  "Insert the text of the file PATH, read as UTF-8 and otherwise as it is.
No line end is converted, and no compression or format is undone."
  (let ((coding-system-for-read 'utf-8-unix)
        (format-alist nil)
        (after-insert-file-functions nil)
        (inhibit-file-name-handlers (cons 'jka-compr-handler inhibit-file-name-handlers))
        (inhibit-file-name-operation 'insert-file-contents))
    (insert-file-contents path)))

(defun harness-redaction--size (path)
  "Return the size in bytes of the file PATH, which may be a link; 0 if gone."
  (or (file-attribute-size (file-attributes (file-truename path))) 0))

(defun harness-redaction--signature (path)
  "Return what tells the content of the file PATH from another: size and time."
  (when-let* ((attrs (file-attributes path 'integer)))
    (list (file-attribute-size attrs) (file-attribute-modification-time attrs))))

(defun harness-redaction--same-signature-p (a b)
  "Non-nil when the signatures A and B are the same."
  (and a b (= (car a) (car b)) (time-equal-p (cadr a) (cadr b))))

(defun harness-redaction-rewrite-file (path text &optional expect)
  "Write TEXT as the new content of the file PATH, atomically; return PATH.
TEXT is written as UTF-8 with no conversion of line ends, to a new file
in PATH's directory, which takes the modes of PATH and then replaces it
by a rename: a reader sees the old file or the new one, never half of
either.  A link is followed, so the file it points to is the one
replaced.  EXPECT, when given, is what `harness-redaction--signature'
returned for PATH when its content was read; a file that changed since
is left alone and `harness-redaction-changed' is signalled."
  (let* ((target (file-truename path))
         (modes (file-modes target))
         (tmp (make-temp-file (expand-file-name ".harness-redact-" (file-name-directory target))))
         (done nil))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8-unix)
                (write-region-annotate-functions nil)
                (write-region-inhibit-fsync nil)
                (inhibit-file-name-handlers (cons 'jka-compr-handler inhibit-file-name-handlers))
                (inhibit-file-name-operation 'write-region))
            (write-region text nil tmp nil 'silent))
          (set-file-modes tmp (or modes #o600))
          (when (and expect
                     (not (harness-redaction--same-signature-p
                           expect (harness-redaction--signature target))))
            (signal 'harness-redaction-changed
                    (list (format "%s changed while it was being redacted; nothing was written"
                                  (abbreviate-file-name target)))))
          (rename-file tmp target t)
          (setq done t))
      (unless done (ignore-errors (delete-file tmp))))
    path))

(defun harness-redaction--binary-p (path)
  "Non-nil when the file PATH has a NUL byte among its first bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path nil 0 harness-redaction--binary-probe)
    (goto-char (point-min))
    (and (search-forward "\0" nil t) t)))

(defun harness-redaction--byte-pairs (secrets)
  "Return the needles of SECRETS as UTF-8 bytes, longest first, as pairs.
The pairs are (BYTES . nil)."
  (let ((seen (make-hash-table :test 'equal))
        (out nil))
    (dolist (p (harness-redaction-pairs secrets))
      (let ((bytes (encode-coding-string (car p) 'utf-8)))
        (unless (or (string-empty-p bytes) (gethash bytes seen))
          (puthash bytes t seen)
          (push (cons bytes nil) out))))
    (harness-redaction--sort-pairs (nreverse out))))

(defun harness-redaction-file-count (path secrets)
  "Return how many times the needles of SECRETS occur in the file PATH.
The needles (`harness-redaction-needles') are looked for as UTF-8 bytes
in the bytes of the file, whatever it is -- text, a log, an SQLite
database -- so no copy hides in what is not text.  The file is read
`harness-redaction--chunk-size' bytes at a time, each read reaching the
longest needle less one byte into the next, and a needle counts where it
starts, so none is missed or counted twice at the end of a chunk.  A
position that two needles match counts once.  A missing file has none."
  (let ((pairs (harness-redaction--byte-pairs secrets)))
    (if (or (null pairs) (not (file-regular-p path)))
        0
      (let* ((size (harness-redaction--size path))
             (stride (max 1 harness-redaction--chunk-size))
             (overlap (1- (apply #'max (mapcar (lambda (p) (length (car p))) pairs))))
             (offset 0) (total 0) (resume 0))
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (while (< offset size)
            (let ((limit (+ offset stride)))
              (erase-buffer)
              (insert-file-contents-literally path nil offset (min size (+ limit overlap)))
              (catch 'window
                (dolist (hit (harness-redaction--buffer-hits
                              pairs (+ (point-min) (max 0 (- resume offset)))))
                  (when (>= (+ offset (1- (car hit))) limit) (throw 'window nil))
                  (cl-incf total)
                  (setq resume (+ offset (1- (cadr hit))))))
              (setq offset limit))))
        total))))

(defun harness-redaction--file-once (path secrets style json-style dry-run on-line)
  "Redact SECRETS in the file PATH in STYLE, once; see `harness-redaction-file'.
JSON-STYLE is how JSON is read and written (see `harness-redaction-jsonl')."
  (let* ((signature (harness-redaction--signature (file-truename path)))
         (pairs (harness-redaction-pairs secrets))
         (count 0))
    (with-temp-buffer
      (harness-redaction--insert-file path)
      (pcase style
        ('text
         (let ((hits (harness-redaction--buffer-hits pairs)))
           (setq count (length hits))
           (unless (or dry-run (null hits)) (harness-redaction--replace-hits hits))))
        ('jsonl
         (pcase-let ((`(,n ,_ ,changes) (harness-redaction--jsonl-buffer secrets json-style on-line)))
           (setq count n)
           (unless (or dry-run (null changes)) (harness-redaction--apply-changes changes))))
        ('json
         (let* ((text (buffer-string))
                (result (harness-redaction--redact-json
                         text (harness-redaction--raw-pairs secrets) pairs json-style on-line)))
           (when result
             (setq count (cdr result))
             (unless dry-run
               (erase-buffer)
               (insert (car result))
               ;; A document that was written again lost its final newline.
               (when (and (string-suffix-p "\n" text) (not (string-suffix-p "\n" (car result))))
                 (insert "\n")))))))
      (when (and (> count 0) (not dry-run))
        (harness-redaction-rewrite-file path (buffer-string) signature)))
    (list :file path :count count :changed (and (> count 0) (not dry-run)))))

(defvar harness-redaction--max-file-size (* 1024 1024 1024)
  "Largest text file, in bytes, that `harness-redaction-file' reads into memory.
A larger one is refused: reading it would starve the process of memory,
and every session with it.  A variable so that tests can lower it.")

(defun harness-redaction-file (path secrets &rest options)
  "Redact SECRETS in the file PATH.  Return (:file PATH :count N :changed BOOL).
N counts the replacements and :changed says whether the file was written
\(never in a dry run).  A missing file has none.  A file with a NUL byte
among its first bytes is binary: it is counted
\(`harness-redaction-file-count') and never changed, and the result
has :binary t as well.  Text is written back atomically with its modes
\(`harness-redaction-rewrite-file'); a file that changes while it is
processed is processed again, up to three times, and then signalled.  A
text file of more than `harness-redaction--max-file-size' bytes is
refused with an error.  OPTIONS:

  :style       `text' (the default) replaces every needle in the text;
               `jsonl' treats each line as JSON as `harness-redaction-jsonl'
               does; `json' treats the file as one JSON document, written
               again whole, and falls back to text when it does not parse;
  :json-style  how JSON is read and written, as the :style of
               `harness-redaction-jsonl': `foreign' (the default) or
               `harness';
  :dry-run     non-nil only counts;
  :on-line     as for `harness-redaction-jsonl' (called again by a
               second try)."
  (let ((style (or (plist-get options :style) 'text))
        (json-style (or (plist-get options :json-style) 'foreign))
        (dry-run (plist-get options :dry-run))
        (on-line (plist-get options :on-line)))
    (unless (memq style '(text jsonl json))
      (harness-redaction--fail "Unknown style %S" style))
    (unless (memq json-style '(harness foreign))
      (harness-redaction--fail "Unknown JSON style %S" json-style))
    (cond
     ((not (file-exists-p path)) (list :file path :count 0 :changed nil))
     ((not (file-regular-p path))
      (harness-redaction--fail "%s is not a regular file" (abbreviate-file-name path)))
     ((harness-redaction--binary-p path)
      (list :file path :count (harness-redaction-file-count path secrets) :changed nil :binary t))
     ((> (harness-redaction--size path) harness-redaction--max-file-size)
      (harness-redaction--fail "%s is too large to redact in memory (%d MiB)"
                               (abbreviate-file-name path)
                               (/ (harness-redaction--size path) 1048576)))
     (t
      (let ((tries 0) (result nil))
        (while (not result)
          (condition-case err
              (setq result (harness-redaction--file-once
                            path secrets style json-style dry-run on-line))
            (harness-redaction-changed
             (when (>= (cl-incf tries) 3) (signal (car err) (cdr err))))))
        result)))))

;;;; Buffers

(defun harness-redaction-buffer (buffer secrets &optional dry-run)
  "Replace SECRETS in BUFFER by their placeholders; return how many.
Every needle (`harness-redaction-needles') is replaced literally, the
placeholder taking the text properties of the text it replaces, in a
read-only buffer too.  A buffer that keeps undo information loses it
when it changes, or when the history holds a secret; the replacements
are not recorded in it.  With DRY-RUN only count."
  (with-current-buffer buffer
    (let ((pairs (harness-redaction-pairs secrets)))
      (save-restriction
        (widen)
        (save-excursion
          (let* ((hits (harness-redaction--buffer-hits pairs))
                 (count (length hits)))
            (unless (or dry-run (null hits))
              (let ((inhibit-read-only t)
                    (buffer-undo-list t))
                (harness-redaction--replace-hits hits)))
            ;; The history is wrong where the buffer changed, and holds the
            ;; text that was taken out of it: both are reasons to drop it.
            (when (and (not dry-run) (consp buffer-undo-list)
                       (or hits (> (cdr (harness-redaction-value buffer-undo-list secrets)) 0)))
              (setq buffer-undo-list nil))
            count))))))

(provide 'harness-redaction)
;;; harness-redaction.el ends here
