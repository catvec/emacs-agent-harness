;;; harness-secrets.el --- Secret references and masking of tool output  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; What the harness knows about secrets that it must keep out of what it
;; stores.  The library lisp/harness-redaction.el does the work of
;; naming a secret by where it can be read, finding it and taking it out
;; of text; this module is its face on the bus.
;;
;; `secrets/shape' lists the keys and types of a JSON file, never its
;; values.  It is how the exact place of a secret in a file is found
;; without reading the secret: the path it returns goes into a reference
;; (:file PATH :json-path P) that stands for the value from then on.
;;
;; Masking.  Tool output is the way a secret gets into a transcript: a
;; command prints a state file, a tool reads a credentials file.  So
;; what a tool returns is masked before anything keeps it or sends it to
;; the model: every secret in it is replaced by the placeholder
;; [redacted: LABEL sha256:FINGERPRINT], which says which secret was
;; here (by the first 8 hex digits of its SHA-256) without giving it
;; away.  Two things find secrets:
;;
;; - The registry holds the values of the sources the user named: the
;;   references in `harness-secrets-sources' and those added with
;;   `secrets/add-source' (kept in secret-sources.json in the state
;;   directory, as references only, never values; `secrets/sources'
;;   lists them, with fingerprints, and `secrets/remove-source' drops a
;;   stored one).  A value is found as it is, and as JSON writes it
;;   (escapes included), wherever it stands, and labelled by its source.
;;   A file is read again when its modification time or size changes and
;;   a variable when its value does, looked at every 5 seconds at most; a
;;   command runs when the source is first read, under `timeout' where
;;   there is one, and only again if the source changes.  A source that
;;   cannot be read is skipped, its error is kept for `secrets/sources'
;;   and logged once, and the values it had when it last could be read
;;   stay in force.
;; - The detectors (`harness-secrets-builtin-detectors') find what
;;   looks like a secret: the token formats of DigitalOcean, AWS and
;;   Spaces keys, GitHub, Anthropic, OpenAI, Slack, Google and Stripe,
;;   PEM private keys, and values assigned to names such as secret,
;;   password or api_key.  They are labelled by their name.  Masking
;;   never touches the inside of a placeholder, so masking text again
;;   changes nothing.
;;
;; The hooks are the `tools/output' filter (the result of a call, ahead
;; of the size guard, so the file an oversized result is saved to is
;; masked too) and the `tools/output-text' filter (progress and note
;; text, the output of a provider's own tool, an error message), both
;; of harness-tools.el; `harness-log-filter-function' (the log); and a
;; `permission/decide' stage that refuses a write whose input holds a
;; placeholder, since a masked secret written into a file would replace
;; the real one.  A result that had something masked says so in its
;; `:meta' (`:masked', the labels, fingerprints and counts), and the
;; agent keeps that on the tool-result node.  A result that masking
;; cannot check is withheld rather than let through.
;;
;; What is on by default, and what it costs.  Masking is on
;; (`harness-secrets-mask'), with the detectors whose formats are
;; unmistakable and the one for assignments of 16 or more characters to
;; a secret-looking name; the JWT detector is off, since a JWT is
;; mostly a session credential that expires.  Nothing is skipped by
;; size: skipping would be a hole.  The cost is a few regexp passes and
;; one exact search per registered value over every result and log
;; line, some 30 milliseconds for a megabyte of output with the default
;; detectors and a fraction of a millisecond for a log line.  The price
;; of that is false positives: a long identifier that follows a name such
;; as `token' now and then, and a model that is shown a placeholder
;; where the text was.  The placeholder shows what happened, and a
;; detector or the whole of masking can be turned off.  A write whose
;; input holds a placeholder is refused, the user able to approve it, so
;; documents that show placeholders need that approval to be edited.
;;
;; Masking cannot recall what a model provider already received, and it
;; keeps nothing from being typed by the user or written by the model;
;; the redaction tools (harness-redact.el) take a secret out of what
;; was stored before.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-redaction)

(defvar harness-state-directory)

;;;; Settings

(defcustom harness-secrets-mask t
  "Non-nil takes secrets out of tool output before anything keeps it.
Every tool result, the progress and notes tools report, the output of a
provider's own tool and the harness log are searched for the secrets of
`harness-secrets-sources' and for what `harness-secrets-detectors' find,
and each is replaced by [redacted: LABEL sha256:FINGERPRINT], before the
text is stored, shown or sent to the model.  The same switch turns off
the guard that refuses to write a placeholder into a file.

It costs a few regexp passes and an exact search per secret over each
result, tens of milliseconds for a megabyte of output.  Results are
never skipped for their size, as a skipped one would leak.  The price
is false positives: a value that looks like a credential is masked
whatever it is, and the model sees a placeholder where it was.  Nil
leaves tool output as it is."
  :type 'boolean
  :group 'harness)

(defcustom harness-secrets-sources nil
  "References to secrets whose values are masked, besides the stored sources.
Each is a plist that names where a secret can be read, so that its value
is never in a call or a transcript.  One of:

  (:file PATH :json-path P)    a string in a JSON file, P being a path such
                               as outputs.key.value.secret; an object or
                               array selected stands for every string in it
  (:file PATH :regexp RE)      group 1 of each match of RE in a file
  (:env NAME)                  an environment variable of the harness
                               process
  (:literal STRING)            the value itself (it is in your init file
                               and in the harness process's configuration
                               file then; prefer a file or a variable)
  (:command STRING)            the output of a shell command, run when the
                               harness starts

and an optional :label, which names the secret in its placeholder.  A
file is read again when its modification time or size changes (checked
every few seconds), a variable when it changes; a command runs once.  A
source that cannot be read is skipped and the reason is shown by
`secrets/sources', and does not stop the others.  Values shorter than
`harness-redaction-min-length' are not masked.  `secrets/add-source'
stores references the same way, but never a literal."
  :type '(repeat
          (plist
           :tag "Secret"
           :options ((:label (string :tag "Label"))
                     (:file (file :tag "File"))
                     (:json-path (string :tag "JSON path"))
                     (:regexp (regexp :tag "Regexp"))
                     (:env (string :tag "Environment variable"))
                     (:literal (string :tag "Literal value"))
                     (:command (string :tag "Command")))))
  :group 'harness)

(defcustom harness-secrets-detectors 'default
  "Which of the built-in detectors look for secrets in tool output.
`default' is the detectors that are on unless asked otherwise (all but
jwt), t is all of them, nil none, and a list of names only those; see
`harness-secrets-builtin-detectors' for the names and what each finds.
The detectors with a fixed format (a token's prefix and length) hardly
ever match anything else; secret-assignment, which masks a value of 16 or
more characters after a name such as secret, password or api_key, is
the one that masks harmless text now and then.  Each detector is a
regexp pass over every result."
  :type '(choice (const :tag "The default detectors" default)
                 (const :tag "All of them" t)
                 (const :tag "None" nil)
                 (repeat :tag "Only these" (symbol :tag "Detector")))
  :group 'harness)

(defcustom harness-secrets-extra-detectors nil
  "Patterns of your own for what to mask, each (NAME REGEXP [GROUP]).
NAME labels the placeholder, REGEXP is an Emacs regexp, matched case
sensitively, and GROUP the number of the group whose text is masked (the
whole match by default).  They run whenever masking is on, whatever
`harness-secrets-detectors' says.  A regexp that fails is skipped and
logged once.  Avoid repeating a group a very long run can match, as
\\(x\\|y\\)*, which can overflow the matcher; a character class does not."
  :type '(repeat (list :tag "Detector"
                       (string :tag "Name")
                       (regexp :tag "Regexp")
                       (integer :tag "Group" :value 0)))
  :group 'harness)

;;;; Detectors

(defun harness-secrets--digit-count-p (value _text _beg _end)
  "Non-nil when VALUE, the match of a detector, holds at least two digits."
  (>= (cl-count-if (lambda (c) (<= ?0 c ?9)) value) 2))

(defun harness-secrets--assignment-value-p (value _text _beg _end)
  "Non-nil when VALUE, what a name is assigned, looks like a secret.
It holds a letter and a digit and does not start like a reference to a
variable or a template ($, < or {).  A value inside a placeholder is
never masked, whatever the detector (`harness-secrets-mask-text')."
  (and (cl-find-if (lambda (c) (or (<= ?a c ?z) (<= ?A c ?Z))) value)
       (cl-find-if (lambda (c) (<= ?0 c ?9)) value)
       (not (memq (aref value 0) '(?$ ?< ?{)))))

(defconst harness-secrets-builtin-detectors
  `((digitalocean-token
     :regexp "\\(?:dop\\|doo\\|dor\\)_v1_[0-9a-f]\\{64\\}[0-9a-f]*"
     :group 0 :default t
     :doc "A DigitalOcean token: dop_v1_, doo_v1_ or dor_v1_ and 64 hex digits.")
    (aws-access-key-id
     :regexp "\\(?:AKIA\\|ASIA\\|ABIA\\|ACCA\\)[A-Z0-9]\\{16\\}"
     :group 0 :default t :bounded t
     :doc "An AWS access key id: AKIA, ASIA, ABIA or ACCA and 16 capitals or digits.")
    (spaces-access-key-id
     :regexp "DO[A-Z0-9]\\{18\\}"
     :group 0 :default t :bounded t :predicate harness-secrets--digit-count-p
     :doc "A DigitalOcean Spaces access key id: DO and 18 capitals or digits, two of them digits at least.")
    (github-token
     :regexp "\\(?:gh[pousr]_[A-Za-z0-9]\\{36\\}[A-Za-z0-9]*\\|github_pat_[A-Za-z0-9_]\\{22\\}[A-Za-z0-9_]*\\)"
     :group 0 :default t
     :doc "A GitHub token: ghp_, gho_, ghu_, ghs_ or ghr_ and 36 letters or digits, or github_pat_ and 22 more.")
    (anthropic-key
     :regexp "sk-ant-[A-Za-z0-9_-]\\{20\\}[A-Za-z0-9_-]*"
     :group 0 :default t
     :doc "An Anthropic API key: sk-ant- and 20 or more characters.")
    (openai-key
     :regexp "sk-\\(?:proj\\|svcacct\\|admin\\)-[A-Za-z0-9_-]\\{20\\}[A-Za-z0-9_-]*"
     :group 0 :default t
     :doc "An OpenAI API key: sk-proj-, sk-svcacct- or sk-admin- and 20 or more characters.")
    (slack-token
     :regexp "xox[abposr]-[A-Za-z0-9-]\\{10\\}[A-Za-z0-9-]*"
     :group 0 :default t
     :doc "A Slack token: xoxa-, xoxb-, xoxp-, xoxo-, xoxs- or xoxr- and 10 or more characters.")
    (google-api-key
     :regexp "AIza[A-Za-z0-9_-]\\{35\\}[A-Za-z0-9_-]*"
     :group 0 :default t
     :doc "A Google API key: AIza and 35 characters.")
    (stripe-key
     :regexp "[rs]k_live_[A-Za-z0-9]\\{16\\}[A-Za-z0-9]*"
     :group 0 :default t
     :doc "A live Stripe key: sk_live_ or rk_live_ and 16 or more characters.")
    (private-key
     :regexp "-----BEGIN [A-Z0-9 ]*PRIVATE KEY\\(?: BLOCK\\)?-----"
     :end "-----END [A-Z0-9 ]*PRIVATE KEY\\(?: BLOCK\\)?-----"
     :group 0 :default t
     :doc "A PEM private key, the whole block from its BEGIN line to its END line (or the key lines that follow a BEGIN line cut short).")
    (secret-assignment
     :regexp "[:=]>?[ \t]*\\(?:\\\\?[\"']\\)?\\([A-Za-z0-9/+_.~-]\\{16\\}[A-Za-z0-9/+_.~-]*=*\\)"
     :before ,(concat
               "\\(?:secret[_-]?access[_-]?key\\|secret[_-]?key\\|client[_-]?secret"
               "\\|api[_-]?key\\|api[_-]?token\\|auth[_-]?token\\|access[_-]?token"
               "\\|refresh[_-]?token\\|private[_-]?key\\|password\\|passwd\\|secret\\|token\\)"
               "\\(?:\\\\?[\"']\\)?[ \t]*\\'")
     :group 1 :default t :case-fold t :late t
     :predicate harness-secrets--assignment-value-p
     :doc "The value of a secret-looking name (secret, secret_key, client_secret, api_key, auth_token, access_token, private_key, password, token and the like, quoted or not, after : or =): 16 or more characters with a letter and a digit.")
    (jwt
     :regexp "eyJ[A-Za-z0-9_-]\\{10\\}[A-Za-z0-9_-]*\\.eyJ[A-Za-z0-9_-]\\{10\\}[A-Za-z0-9_-]*\\.[A-Za-z0-9_-]\\{10\\}[A-Za-z0-9_-]*"
     :group 0 :default nil
     :doc "A JSON Web Token: three dot-separated parts, the first two starting eyJ.  Off by default."))
  "The detectors that look for what is shaped like a secret, NAME -> SPEC.
SPEC is a plist: `:regexp', an Emacs regexp; `:group', the group whose
text is masked (0, the match, by default); `:default', non-nil for a
detector that is on unless `harness-secrets-detectors' says otherwise;
`:doc', what it finds; and optionally `:predicate', a function of the
text matched, the whole text and the match's start and end that
returns nil for a match that is none after all; `:bounded', non-nil to
refuse a match with a letter or digit just before or after it;
`:case-fold', non-nil to match without regard to case; `:before', a
regexp, anchored at its end, that the text just before a match has to end
in (looking back 48 characters at most); `:end', the
regexp that closes a block `:regexp' opens (the match then runs to the
closing match, or over the lines of key material that follow when it
was cut short); and `:late', non-nil for a detector tried after the
others, where a text that two match is given to the first.")

(defconst harness-secrets--placeholder-regexp
  "\\[redacted: [^][\n]\\{0,512\\} sha256:[0-9a-f]\\{8\\}\\]"
  "Regexp for a placeholder, which nothing is ever masked inside.
A label is 80 characters at most, up to six times that once JSON has
escaped it; the bound keeps a run of \"[redacted: \" from being searched
again to its end at every one of them.  A label holds no bracket, so
text that only opens a placeholder before a real one, and may hold a
secret, is not taken for one.")

(defconst harness-secrets--placeholder-like-regexp
  "\\[redacted: [^]\n]\\{0,512\\} sha256:[0-9a-f]\\{8\\}\\]"
  "Regexp for anything that reads like a placeholder, a bracket in its label too.
The guard against writing one uses it.")

(defconst harness-secrets--block-limit 65536
  "Longest block, in characters, a footer closes: a PEM key is a few thousand.")

(defvar harness-secrets--detector-failures (make-hash-table :test 'equal)
  "Detector label -> t once its failure was logged.")

(defun harness-secrets--detector-name (name)
  "Return NAME, a detector's name as a symbol or a string, as a string."
  (if (stringp name) name (format "%s" name)))

(defun harness-secrets--extra-detector (entry)
  "Return the detector ENTRY, (NAME REGEXP [GROUP]), stands for, or nil."
  (when (and (consp entry) (stringp (cadr entry)) (car entry))
    (cons (harness-secrets--detector-name (car entry))
          (list :regexp (cadr entry)
                :group (if (integerp (nth 2 entry)) (nth 2 entry) 0)))))

(defun harness-secrets--chosen-detectors ()
  "Work out the detectors in force; see `harness-secrets--active-detectors'."
  (let* ((builtins harness-secrets-builtin-detectors)
         (chosen (cond
                  ((null harness-secrets-detectors) nil)
                  ((eq harness-secrets-detectors t) builtins)
                  ((eq harness-secrets-detectors 'default)
                   (cl-remove-if-not (lambda (d) (plist-get (cdr d) :default)) builtins))
                  ((listp harness-secrets-detectors)
                   (let ((names (mapcar #'harness-secrets--detector-name harness-secrets-detectors)))
                     (cl-remove-if-not (lambda (d) (member (symbol-name (car d)) names)) builtins)))))
         (early (cl-remove-if (lambda (d) (plist-get (cdr d) :late)) chosen))
         (late (cl-remove-if-not (lambda (d) (plist-get (cdr d) :late)) chosen))
         (extras (delq nil (mapcar #'harness-secrets--extra-detector
                                   (and (listp harness-secrets-extra-detectors)
                                        harness-secrets-extra-detectors)))))
    (append early extras late)))

(defvar harness-secrets--detectors-cache nil
  "The last answer of `harness-secrets--active-detectors', (SETTINGS . DETECTORS).
SETTINGS is a copy of what it was worked out from.")

(defun harness-secrets--active-detectors ()
  "Return the detectors in force, (NAME . SPEC), in the order they are tried.
That is the built-in ones `harness-secrets-detectors' chooses, then those
of `harness-secrets-extra-detectors', then the built-in ones marked
`:late'.  A text that two detectors find is given to the first, so one
that a specific format and a plain assignment both match is labelled
by the format.  The answer is kept while the settings stay as they are."
  (let ((settings (list harness-secrets-detectors harness-secrets-extra-detectors
                        harness-secrets-builtin-detectors)))
    (unless (and harness-secrets--detectors-cache
                 (equal settings (car harness-secrets--detectors-cache)))
      (setq harness-secrets--detectors-cache
            (cons (copy-tree settings) (harness-secrets--chosen-detectors))))
    (cdr harness-secrets--detectors-cache)))

(defun harness-secrets--alnum-p (char)
  "Non-nil when CHAR is an ASCII letter or digit."
  (or (<= ?0 char ?9) (<= ?A char ?Z) (<= ?a char ?z)))

(defun harness-secrets--bounded-p (text beg end)
  "Non-nil when TEXT has no letter or digit just before BEG or at END."
  (and (or (<= beg 0) (not (harness-secrets--alnum-p (aref text (1- beg)))))
       (or (>= end (length text)) (not (harness-secrets--alnum-p (aref text end))))))

(defconst harness-secrets--before-window 48
  "How far back from a match a `:before' regexp of a detector looks.")

(defun harness-secrets--before-p (text start before)
  "Non-nil when the text before START in TEXT ends in a match of BEFORE.
BEFORE is anchored at its end, so it has to match right up to START,
and reaches back `harness-secrets--before-window' characters at most.
A detector uses it to find its candidates by what follows the part it
has to check (a separator, which is rare) instead of trying every
position of the text for that part."
  (string-match-p before (substring text (max 0 (- start harness-secrets--before-window)) start)))

(defun harness-secrets--body-end (text from)
  "Return where the lines of key material in TEXT that follow FROM end.
FROM is the end of a line; the lines that follow are taken while they
are base64, a PEM header (Proc-Type, DEK-Info) or blank.  The result is
the end of the last one that holds something, FROM when none does."
  (let ((pos from) (last from) (length (length text)))
    (while (and (< pos length) (eq (aref text pos) ?\n))
      (let* ((start (1+ pos))
             (stop (or (string-search "\n" text start) length))
             (line (substring text start stop)))
        (if (string-match-p
             "\\`\\(?:[A-Za-z0-9+/=]+\\|\\(?:Proc-Type\\|DEK-Info\\):.*\\)?\r?\\'" line)
            (progn (unless (string-match-p "\\`\r?\\'" line) (setq last stop))
                   (setq pos stop))
          (setq pos length))))
    last))

(defun harness-secrets--block-end (text from end-regexp)
  "Return where the block of TEXT that opens just before FROM ends, or nil.
That is the end of the next match of END-REGEXP when it is near enough,
else the end of the key lines that follow (`harness-secrets--body-end'),
and nil when there is neither: a header alone holds no secret."
  (if (and (string-match end-regexp text from)
           (<= (- (match-end 0) from) harness-secrets--block-limit))
      (match-end 0)
    (let ((end (harness-secrets--body-end text from)))
      (and (> end from) end))))

(defun harness-secrets--detector-failed (label err)
  "Log once that the detector LABEL failed with ERR, which is never printed whole."
  (unless (gethash label harness-secrets--detector-failures)
    (puthash label t harness-secrets--detector-failures)
    (harness-log 'warn "secrets: the %s detector failed (%s) and is skipped for this text"
                 label (if (consp err) (car err) err))))

(defun harness-secrets--scan-detector (detector text)
  "Return the spans of TEXT that DETECTOR, (NAME . SPEC), finds.
A span is (BEG END LABEL); the spans are in order and none overlaps
another.  A detector that fails finds nothing, and is logged once."
  (let* ((label (car detector))
         (spec (cdr detector))
         (regexp (plist-get spec :regexp))
         (group (or (plist-get spec :group) 0))
         (predicate (plist-get spec :predicate))
         (bounded (plist-get spec :bounded))
         (end-regexp (plist-get spec :end))
         (before (plist-get spec :before))
         (case-fold-search (and (plist-get spec :case-fold) t))
         (label (harness-secrets--detector-name label))
         (length (length text))
         (pos 0) (spans nil))
    (condition-case err
        (progn
          (while (and (<= pos length) (string-match regexp text pos))
            (let ((start (match-beginning 0))
                  (beg (match-beginning group))
                  (end (match-end group)))
              (when (and end-regexp beg end)
                (setq end (harness-secrets--block-end text end end-regexp)))
              (if (and beg end (< beg end)
                       (or (null before) (harness-secrets--before-p text start before))
                       (or (not bounded) (harness-secrets--bounded-p text beg end))
                       (or (null predicate) (funcall predicate (substring text beg end) text beg end)))
                  (progn (push (list beg end label) spans)
                         (setq pos end))
                (setq pos (1+ start)))))
          (nreverse spans))
      (error (harness-secrets--detector-failed label err) nil))))

;;;; Stored sources

(defconst harness-secrets--sources-file "secret-sources.json"
  "Store document holding the references added with `secrets/add-source'.
It holds references and nothing else, never a value.")

(defconst harness-secrets--ref-keys '(:file :json-path :regexp :env :literal :command :label)
  "The keys of a reference.")

(defun harness-secrets--ref-key (key)
  "Return KEY, a key of a reference as a client may spell it, as its keyword.
`json_path' and `jsonPath' are `:json-path'."
  (let* ((case-fold-search nil)
         (name (string-remove-prefix ":" (symbol-name key)))
         (name (replace-regexp-in-string "\\([a-z]\\)\\([A-Z]\\)" "\\1-\\2" name t)))
    (intern (concat ":" (downcase (string-replace "_" "-" name))))))

(defun harness-secrets--normalise-ref (ref)
  "Return REF, a reference to store, with only its known keys and a full path.
A literal is refused: it would put a value on disk."
  (unless (and (consp ref) (keywordp (car ref)) (cl-evenp (length ref)))
    (signal 'harness-error (list "A reference is a plist: :file with :json-path or :regexp, :env or :command")))
  (let ((out nil))
    (cl-loop for (key value) on ref by #'cddr
             for k = (harness-secrets--ref-key key)
             when (memq k harness-secrets--ref-keys)
             do (setq out (plist-put out k value)))
    (when (plist-member out :literal)
      (signal 'harness-error
              (list "A literal value is not stored: that would put the secret on disk. Name where it can be read (a file and a JSON path or a regexp, a variable, a command), or put the literal in harness-secrets-sources")))
    (when (stringp (plist-get out :file))
      (setq out (plist-put out :file (expand-file-name (plist-get out :file)))))
    ;; In a fixed order, so equal references compare equal.
    (cl-loop for k in harness-secrets--ref-keys
             when (plist-member out k) append (list k (plist-get out k)))))

(defun harness-secrets--ref-holds-value-p (ref secrets)
  "Non-nil when REF spells out the value of one of SECRETS, quoted or not.
A regexp may carry a value with its special characters quoted, so the
strings of REF are looked at as they are and with their backslashes taken
out."
  (let ((strings nil))
    (cl-loop for (_key value) on ref by #'cddr
             when (stringp value) do (push value strings))
    (setq strings (append strings
                          (mapcar (lambda (s) (replace-regexp-in-string "\\\\\\(.\\)" "\\1" s t))
                                  strings)))
    (cl-some (lambda (secret)
               (let ((value (plist-get secret :value)))
                 (cl-some (lambda (s) (string-search value s)) strings)))
             secrets)))

(defun harness-secrets--read-stored ()
  "Return the stored sources, plists (:id ID :ref REF :added TIME)."
  (let ((doc (and (harness-method-exists-p 'store/load)
                  (harness-call 'store/load harness-secrets--sources-file))))
    (cl-remove-if-not (lambda (s) (and (consp s) (stringp (plist-get s :id)) (consp (plist-get s :ref))))
                      (and (consp doc) (plist-get doc :sources)))))

(defun harness-secrets--write-stored (sources)
  "Store SOURCES, plists (:id ID :ref REF :added TIME), as the added sources."
  (harness-call 'store/save harness-secrets--sources-file
                (list :sources (harness-json-array sources))))

;;;; The registry of values

(defvar harness-secrets--refresh-interval 5
  "Seconds between checks whether a source's file or variable changed.")

(defvar harness-secrets--retry-interval 60
  "Seconds before a file or variable that failed to read is tried again.")

(defconst harness-secrets--command-timeout 20
  "Seconds a command source may run, where `timeout' is installed.")

(defvar harness-secrets--entries nil
  "The registry: one plist for each source, in order, config sources first.
An entry is (:id :origin :ref :label :source :secrets :stamp :attempted
:error :logged).  It holds the values of its source, in memory only.")

(defvar harness-secrets--index nil
  "What masking looks for, (:pairs PAIRS :owners TABLE), or nil before a refresh.
PAIRS are the (NEEDLE . REPLACEMENT) of `harness-redaction-pairs' for every
value, longest needle first, and TABLE maps a replacement to its secret.")

(defvar harness-secrets--checked 0.0
  "When the registry last looked at its sources, a `float-time'.")

(defvar harness-secrets--config-seen :unset
  "The value of `harness-secrets-sources' the registry was last built from.")

(defvar harness-secrets--state-seen nil
  "The state directory the registry was last built for.")

(defvar harness-secrets--refreshing nil
  "Non-nil while the registry refreshes, which logs and so masks.")

(defun harness-secrets-forget ()
  "Forget the registry; the next masking builds it again from its sources."
  (setq harness-secrets--entries nil
        harness-secrets--index nil
        harness-secrets--checked 0.0
        harness-secrets--config-seen :unset
        harness-secrets--state-seen nil
        harness-secrets--detectors-cache nil)
  (clrhash harness-secrets--detector-failures))

(defun harness-secrets--ref-kind (ref)
  "Return what REF reads: `file', `env', `literal', `command', or nil."
  (and (consp ref)
       (cond ((stringp (plist-get ref :file)) 'file)
             ((stringp (plist-get ref :env)) 'env)
             ((stringp (plist-get ref :literal)) 'literal)
             ((stringp (plist-get ref :command)) 'command))))

(defun harness-secrets--stamp (ref kind)
  "Return what tells whether the source REF, of KIND, changed since it was read.
For a file its modification time and size, for a variable its value."
  (pcase kind
    ('file (let ((attrs (ignore-errors
                          (file-attributes (file-truename (expand-file-name (plist-get ref :file)))))))
             (and attrs (list (file-attribute-modification-time attrs)
                              (file-attribute-size attrs)))))
    ('env (getenv (plist-get ref :env)))))

(defun harness-secrets--runnable (ref)
  "Return REF as `harness-redaction-resolve' is to run it.
A command is run under `timeout' where there is one, so that a command
that waits for input cannot hold the harness."
  (if (and (stringp (plist-get ref :command)) (executable-find "timeout"))
      (plist-put (copy-sequence ref) :command
                 (format "timeout %d %s %s %s" harness-secrets--command-timeout
                         (shell-quote-argument shell-file-name)
                         (shell-quote-argument shell-command-switch)
                         (shell-quote-argument (plist-get ref :command))))
    ref))

(defun harness-secrets--error-text (err)
  "Return what ERR says, which the redaction library keeps free of values."
  (let ((text (if (and (consp err) (stringp (cadr err)))
                  (cadr err)
                (format "%s" (if (consp err) (car err) err)))))
    (truncate-string-to-width text 300 nil nil "...")))

(defun harness-secrets--resolve-entry (prev origin id ref stamp now &optional quiet)
  "Return the registry entry for REF, read now.
PREV is the entry REF had before, whose values stay when the source can
no longer be read.  ORIGIN is `config' or `stored', ID the entry's id
and STAMP what `harness-secrets--stamp' said.  A failure is kept in the
entry's `:error' and logged once, unless QUIET."
  (let ((base (list :id id :origin origin :ref ref :stamp stamp :attempted now
                    :label (plist-get ref :label))))
    (condition-case err
        (let ((resolved (harness-redaction-resolve (harness-secrets--runnable ref))))
          (append base (list :source (plist-get resolved :source)
                             :secrets (plist-get resolved :secrets))))
      (error
       (let ((text (harness-secrets--error-text err))
             (source (harness-redaction-describe-source ref)))
         (unless (or quiet (equal text (plist-get prev :logged)))
           (harness-log 'warn "secrets: cannot read %s: %s" source text))
         (append base (list :source source
                            :secrets (plist-get prev :secrets)
                            :error text :logged text)))))))

(defun harness-secrets--with-identity (entry origin id)
  "Return ENTRY, a registry entry, as the source ORIGIN, ID."
  (if (and (equal id (plist-get entry :id)) (eq origin (plist-get entry :origin)))
      entry
    (plist-put (plist-put (copy-sequence entry) :id id) :origin origin)))

(defun harness-secrets--update-entry (prev origin id ref now)
  "Return the registry entry for REF: PREV, the entry it had, or one read now.
ORIGIN and ID say which source it is, as `harness-secrets--all-sources'
gives them, and NOW is the time.  PREV stays while its file (or
variable) is as it was, and a source that failed is tried again only
when its file or variable changed, or after
`harness-secrets--retry-interval'; a command or a literal is never
read again."
  (let* ((kind (harness-secrets--ref-kind ref))
         (stamp (harness-secrets--stamp ref kind)))
    (cond
     ((and prev (not (plist-get prev :error)) (equal stamp (plist-get prev :stamp)))
      (harness-secrets--with-identity prev origin id))
     ((and prev (plist-get prev :error)
           (or (memq kind '(command literal))
               (and (equal stamp (plist-get prev :stamp))
                    (< (- now (or (plist-get prev :attempted) 0)) harness-secrets--retry-interval))))
      (harness-secrets--with-identity prev origin id))
     (t (harness-secrets--resolve-entry prev origin id ref stamp now)))))

(defun harness-secrets--all-sources ()
  "Return the sources in force, (ORIGIN ID REF): the setting's, then the stored."
  (let ((n 0))
    (append
     (cl-loop for ref in (and (listp harness-secrets-sources) harness-secrets-sources)
              when (consp ref)
              collect (list 'config (format "config-%d" (cl-incf n)) ref))
     (mapcar (lambda (s) (list 'stored (plist-get s :id) (plist-get s :ref)))
             (harness-secrets--read-stored)))))

(defun harness-secrets--rebuild-index (basis)
  "Build `harness-secrets--index' from BASIS, the values of the registry's entries.
BASIS is the list of each entry's secrets; it is kept in the index to tell
later whether the entries still hold what it was built from."
  (let ((secrets (apply #'append basis))
        (owners (make-hash-table :test 'equal)))
    (dolist (secret secrets)
      (dolist (pair (harness-redaction-pairs (list secret)))
        (unless (gethash (cdr pair) owners) (puthash (cdr pair) secret owners))))
    (setq harness-secrets--index
          (list :pairs (harness-redaction-pairs secrets) :owners owners :basis basis))))

(defun harness-secrets--index-current-p (basis)
  "Non-nil when the index was built from BASIS, the entries' secrets, as they are."
  (let ((built (plist-get harness-secrets--index :basis)))
    (and harness-secrets--index
         (= (length built) (length basis))
         (cl-every #'eq built basis))))

(defun harness-secrets--refresh ()
  "Look at every source again; read those that are new or changed.
The index is rebuilt when any of them is."
  (let ((harness-secrets--refreshing t)
        (now (float-time))
        (old harness-secrets--entries)
        (entries nil))
    (setq harness-secrets--checked now
          harness-secrets--config-seen (copy-tree harness-secrets-sources)
          harness-secrets--state-seen harness-state-directory)
    (pcase-dolist (`(,origin ,id ,ref) (harness-secrets--all-sources))
      (let ((prev (cl-find ref old :key (lambda (e) (plist-get e :ref)) :test #'equal)))
        (push (harness-secrets--update-entry prev origin id ref now) entries)))
    (setq entries (nreverse entries)
          harness-secrets--entries entries)
    (let ((basis (mapcar (lambda (e) (plist-get e :secrets)) entries)))
      (unless (harness-secrets--index-current-p basis)
        (harness-secrets--rebuild-index basis)))
    harness-secrets--index))

(defun harness-secrets--due-p ()
  "Non-nil when the registry is to look at its sources again."
  (or (null harness-secrets--index)
      (> (- (float-time) harness-secrets--checked) harness-secrets--refresh-interval)
      (not (equal harness-secrets-sources harness-secrets--config-seen))
      (not (equal harness-state-directory harness-secrets--state-seen))))

(defun harness-secrets--registry ()
  "Return what masking looks for (`harness-secrets--index'), refreshed when due.
It never signals: a refresh that fails is logged, and the registry stays
as it was."
  (unless harness-secrets--refreshing
    (when (harness-secrets--due-p)
      (condition-case err
          (harness-secrets--refresh)
        (error (setq harness-secrets--checked (float-time))
               ;; With no index yet, an empty one: the next try waits its turn.
               (unless harness-secrets--index
                 (setq harness-secrets--index (list :pairs nil :owners (make-hash-table :test 'equal)
                                                    :basis nil)))
               (harness-log 'error "secrets: refreshing the sources failed (%s)"
                            (if (consp err) (car err) err))))))
  harness-secrets--index)

(defun harness-secrets--describe-entry (entry)
  "Describe the registry ENTRY for a client, without any value."
  (let ((secrets (plist-get entry :secrets)))
    (append (list :id (plist-get entry :id)
                  :label (or (plist-get entry :label)
                             (plist-get (car secrets) :label)
                             "secret")
                  :source (plist-get entry :source)
                  :origin (plist-get entry :origin)
                  :values (length secrets)
                  :fingerprints (mapcar (lambda (s) (plist-get s :fingerprint)) secrets))
            (and (plist-get entry :error) (list :error (plist-get entry :error))))))

(harness-defmethod secrets/sources ()
  "List the sources of the secrets that tool output is masked of, without a value.
Each is (:id ID :label LABEL :source DESCRIPTION :origin ORIGIN :values N
:fingerprints (F...) :error MESSAGE).  ORIGIN is `config' for a source of
`harness-secrets-sources' (its ID is config-N) and `stored' for one added
with `secrets/add-source'.  DESCRIPTION names the file and the path or
regexp, or the variable; N is how many values it holds and F the first 8
hex digits of the SHA-256 of each; MESSAGE, present when the source
cannot be read now, says why.  Files and variables are looked at again."
  (harness-secrets--refresh)
  (mapcar #'harness-secrets--describe-entry harness-secrets--entries))

(harness-defmethod secrets/add-source (ref)
  "Add the source REF to those whose values tool output is masked of; return it.
REF is a reference: (:file PATH :json-path P), (:file PATH :regexp RE),
\(:env NAME) or (:command STRING), with an optional :label.  It is read
now, which proves it names a value, and kept in secret-sources.json in
the state directory: the reference only, never a value, so a literal is
refused, and so is a reference that holds the value it names.  Adding a
source already there changes nothing.  Return the source as
`secrets/sources' lists it."
  (let* ((ref (harness-secrets--normalise-ref ref))
         (existing (progn (harness-secrets--refresh)
                          (cl-find ref harness-secrets--entries
                                   :key (lambda (e) (plist-get e :ref)) :test #'equal))))
    (if existing
        (harness-secrets--describe-entry existing)
      (let* ((id (concat "src-" (harness-short-id 6)))
             (entry (harness-secrets--resolve-entry
                     nil 'stored id ref
                     (harness-secrets--stamp ref (harness-secrets--ref-kind ref)) (float-time) t)))
        (when (plist-get entry :error)
          (signal 'harness-error (list (plist-get entry :error))))
        (when (harness-secrets--ref-holds-value-p ref (plist-get entry :secrets))
          (signal 'harness-error
                  (list "The reference holds the secret's value itself: name where it can be read instead")))
        (harness-secrets--write-stored
         (append (harness-secrets--read-stored) (list (list :id id :ref ref :added (float-time)))))
        ;; The entry just read stands in for the one the refresh would read.
        (setq harness-secrets--entries (append harness-secrets--entries (list entry)))
        (harness-secrets--refresh)
        (harness-secrets--describe-entry
         (cl-find id harness-secrets--entries :key (lambda (e) (plist-get e :id)) :test #'equal))))))

(harness-defmethod secrets/remove-source (id)
  "Remove the stored source ID, as `secrets/sources' lists it.
Return (:id ID :removed t).  A source of `harness-secrets-sources' is
the setting's to change."
  (let ((stored (harness-secrets--read-stored)))
    (cond
     ((cl-find id stored :key (lambda (s) (plist-get s :id)) :test #'equal)
      (harness-secrets--write-stored
       (cl-remove id stored :key (lambda (s) (plist-get s :id)) :test #'equal))
      (harness-secrets--refresh)
      (list :id id :removed t))
     ((and (stringp id) (string-prefix-p "config-" id))
      (signal 'harness-error
              (list (format "%s is a source of harness-secrets-sources: change that option" id))))
     (t (signal 'harness-error (list (format "No stored source %s" id)))))))

;;;; Masking

(defun harness-secrets--placeholder-spans (text)
  "Return the spans (BEG END) of the placeholders in TEXT, in order."
  (when (string-search "[redacted: " text)
    (let ((pos 0) (spans nil))
      (while (string-match harness-secrets--placeholder-regexp text pos)
        (push (list (match-beginning 0) (match-end 0)) spans)
        (setq pos (match-end 0)))
      (nreverse spans))))

(defun harness-secrets--cut-span (span beg end)
  "Return the part of SPAN from BEG to END, as a span of its own.
It has SPAN's label and, once masked, a fingerprint and placeholder of
its own, worked out from the text it covers."
  (list beg end (nth 2 span) nil nil))

(defun harness-secrets--add-spans (accepted new)
  "Return ACCEPTED, spans in order, with the spans of NEW added where they fit.
A span is a list that starts (BEG END).  NEW is in order too and overlaps
itself nowhere.  A span of NEW that overlaps one of ACCEPTED keeps the
parts outside it, as spans of their own, so that a secret is masked
whole whatever was masked beside it; the first to claim a text keeps it.
NEW is changed."
  (let ((out nil))
    (while (or accepted new)
      (let ((a (car accepted)) (n (car new)))
        (cond
         ((null n) (push a out) (pop accepted))
         ((null a) (push n out) (pop new))
         ;; N ends before A starts, or A before N.
         ((<= (nth 1 n) (nth 0 a)) (push n out) (pop new))
         ((<= (nth 1 a) (nth 0 n)) (push a out) (pop accepted))
         (t
          ;; They overlap: what N has before A is its own, and what it has
          ;; after A is placed against the spans that follow.
          (when (< (nth 0 n) (nth 0 a))
            (push (harness-secrets--cut-span n (nth 0 n) (nth 0 a)) out))
          (if (> (nth 1 n) (nth 1 a))
              (setcar new (harness-secrets--cut-span n (nth 1 a) (nth 1 n)))
            (pop new))))))
    (nreverse out)))

(defun harness-secrets--mask (text pairs owners detectors)
  "Return (MASKED . HITS) for TEXT; see `harness-secrets-mask-text'.
PAIRS and OWNERS are the registry's (`harness-secrets--index') and
DETECTORS the ones in force."
  ;; A span is (BEG END LABEL FINGERPRINT REPLACEMENT); a placeholder already
  ;; in TEXT is (BEG END), which keeps everything else off it.
  (let ((spans (harness-secrets--placeholder-spans text)))
    ;; The values of the registry first.
    (when pairs
      (when-let* ((hits (harness-redaction--string-hits text pairs)))
        (setq spans (harness-secrets--add-spans
                     spans
                     (mapcar (lambda (h)
                               (let ((secret (gethash (cddr h) owners)))
                                 (list (car h) (cadr h) (plist-get secret :label)
                                       (plist-get secret :fingerprint) (cddr h))))
                             hits)))))
    (dolist (detector detectors)
      (when-let* ((found (harness-secrets--scan-detector detector text)))
        (setq spans (harness-secrets--add-spans spans found))))
    ;; The placeholders were there to keep the rest off them.
    (setq spans (cl-remove-if-not (lambda (span) (nth 2 span)) spans))
    (if (null spans)
        (cons text nil)
      (let ((pieces nil) (pos 0) (table (make-hash-table :test 'equal)) (order nil))
        (dolist (s spans)
          (let* ((beg (nth 0 s)) (end (nth 1 s)) (label (nth 2 s))
                 (fingerprint (or (nth 3 s) (harness-redaction-fingerprint (substring text beg end))))
                 (replacement (or (nth 4 s)
                                  (harness-redaction-placeholder
                                   (list :label label :fingerprint fingerprint))))
                 (key (cons label fingerprint)))
            (push (substring text pos beg) pieces)
            (push replacement pieces)
            (setq pos end)
            (if-let* ((cell (gethash key table)))
                (cl-incf (cdr cell))
              (let ((cell (cons key 1)))
                (puthash key cell table)
                (push cell order)))))
        (push (substring text pos) pieces)
        (cons (mapconcat #'identity (nreverse pieces) "")
              (mapcar (lambda (cell)
                        (list :label (car (car cell)) :fingerprint (cdr (car cell)) :count (cdr cell)))
                      (nreverse order)))))))

(defconst harness-secrets--max-passes 4
  "Most times masking goes over a text that something was masked in.")

(defun harness-secrets--merge-hits (hits more)
  "Return HITS, a list of (:label :fingerprint :count), with MORE added to it.
The counts of a secret in both are added; the others come after."
  (let ((out (mapcar #'copy-sequence hits)))
    (dolist (hit more)
      (if-let* ((same (cl-find-if (lambda (h) (and (equal (plist-get h :label) (plist-get hit :label))
                                                   (equal (plist-get h :fingerprint) (plist-get hit :fingerprint))))
                                  out)))
          (plist-put same :count (+ (plist-get same :count) (plist-get hit :count)))
        (setq out (append out (list (copy-sequence hit))))))
    out))

(defun harness-secrets-mask-text (text)
  "Take the secrets out of TEXT; return (MASKED . HITS).
Each secret is replaced by [redacted: LABEL sha256:FINGERPRINT].  The
values of the registry come first, found as they are and as JSON
escapes them, the longest first, labelled by their source; then the
detectors in force (`harness-secrets-detectors'), labelled by their
name, mask the text they find.  Nothing is masked inside a placeholder
already there, so masking text again changes nothing: where masking one
secret leaves the next, which it touched, standing clear of what it was
glued to, the text is gone over again, a few times at most.  HITS lists
what was masked, (:label LABEL :fingerprint F :count N) for each, in
the order they first appear, and is nil when nothing was; MASKED is then
TEXT itself.  The result holds neither a secret nor a snippet of the
text around it.  A TEXT that is not a string is returned as it is."
  (if (or (not (stringp text)) (string-empty-p text))
      (cons text nil)
    (save-match-data
      (let* ((index (harness-secrets--registry))
             (pairs (plist-get index :pairs))
             (owners (plist-get index :owners))
             (detectors (harness-secrets--active-detectors)))
        (if (and (null pairs) (null detectors))
            (cons text nil)
          (let* ((result (harness-secrets--mask text pairs owners detectors))
                 (passes 1))
            (while (and (cdr result) (< passes harness-secrets--max-passes))
              (let ((again (harness-secrets--mask (car result) pairs owners detectors)))
                (if (null (cdr again))
                    (setq passes harness-secrets--max-passes)
                  (setq result (cons (car again) (harness-secrets--merge-hits (cdr result) (cdr again)))
                        passes (1+ passes)))))
            result))))))

;;;; The filters

(defconst harness-secrets--withheld
  "[output withheld: it could not be checked for secrets]"
  "What stands in for text that masking failed on.")

(defun harness-secrets--filter-output (result &rest _)
  "Take the secrets out of the output of RESULT, the `tools/output' filter.
Return RESULT with the secrets in its `:content' masked, and what was
masked added to its `:meta' as `:masked' (see `harness-secrets-mask-text'
for its shape).  A result masking fails on has its output withheld: a
secret must not get through for the want of a check."
  (let ((content (plist-get result :content)))
    (if (not (and harness-secrets-mask (stringp content) (not (string-empty-p content))))
        result
      (condition-case err
          (pcase-let ((`(,masked . ,hits) (harness-secrets-mask-text content)))
            (if (null hits)
                result
              (let ((meta (plist-get result :meta))
                    (new (plist-put (copy-sequence result) :content masked)))
                (plist-put new :meta (plist-put (copy-sequence meta) :masked
                                                (append (plist-get meta :masked) hits))))))
        (error
         (harness-log 'error "secrets: masking a tool result failed (%s); its output is withheld"
                      (if (consp err) (car err) err))
         (plist-put (plist-put (copy-sequence result) :content harness-secrets--withheld)
                    :is-error t))))))

(defun harness-secrets--filter-text (text &rest _)
  "Take the secrets out of TEXT, the `tools/output-text' filter."
  (if (not (and harness-secrets-mask (stringp text) (not (string-empty-p text))))
      text
    (condition-case err
        (car (harness-secrets-mask-text text))
      (error
       (harness-log 'error "secrets: masking tool text failed (%s); it is withheld"
                    (if (consp err) (car err) err))
       harness-secrets--withheld))))

(defun harness-secrets--filter-log (message)
  "Take the secrets out of MESSAGE, a log line; `harness-log-filter-function'."
  (if harness-secrets-mask
      (car (harness-secrets-mask-text message))
    message))

(defun harness-secrets--input-placeholder-p (input)
  "Non-nil when INPUT, the input of a tool call, holds a placeholder."
  (let ((text (condition-case nil
                  (harness-json-encode-text input)
                (error (format "%S" input)))))
    (and (string-search "[redacted: " text)
         (string-match-p harness-secrets--placeholder-like-regexp text)
         t)))

(defun harness-secrets--write-guard (decision next request)
  "Refuse a write whose input holds a placeholder; the `permission/decide' stage.
A placeholder stands where a secret was masked in what the model read; a
write that puts it into a file puts it where the secret was.  The refusal
is final and says what to do instead.  DECISION is handed to NEXT as it is
for any other call; REQUEST is the call."
  (if (and harness-secrets-mask
           (equal (format "%s" (plist-get request :kind)) "write")
           (harness-secrets--input-placeholder-p (plist-get request :input)))
      (funcall next
               (list :behavior 'deny :final t
                     :reason "its input holds a [redacted: ...] placeholder, and a write would put the placeholder in a file where a secret was"
                     :hint "Edit around the placeholder or leave that part of the file alone, and say in your answer what the user has to put there. If the placeholder text itself is what belongs in the file, the user can approve this call."))
    (funcall next decision)))

;;;; Installing

(defun harness-secrets--install ()
  "Install the filters of masking.  Safe to call again."
  (harness-add-filter 'tools/output #'harness-secrets--filter-output 5)
  (harness-add-filter 'tools/output-text #'harness-secrets--filter-text 5)
  (harness-add-filter 'permission/decide #'harness-secrets--write-guard 3)
  (setq harness-log-filter-function #'harness-secrets--filter-log))

(defun harness-secrets--uninstall ()
  "Remove the filters of masking."
  (cancel-function-timers #'harness-secrets--prime)
  (harness-remove-filter 'tools/output #'harness-secrets--filter-output)
  (harness-remove-filter 'tools/output-text #'harness-secrets--filter-text)
  (harness-remove-filter 'permission/decide #'harness-secrets--write-guard)
  (when (eq harness-log-filter-function #'harness-secrets--filter-log)
    (setq harness-log-filter-function nil)))

(defun harness-secrets--prime ()
  "Read the sources now, so that a command runs before the first result."
  (harness-secrets--registry))

(defun harness-secrets--init ()
  "Start masking, and read the sources shortly, off the start itself."
  (harness-secrets--install)
  (run-at-time 2 nil #'harness-secrets--prime))

;; A reload does not run `:init' again for a ready module.
(harness-secrets--install)

(harness-defmethod secrets/shape (file &optional json-path)
  "Return the shape of the JSON document FILE, without any of its values.
JSON-PATH, a path in the syntax `harness-redaction-json-path-parse'
reads, limits the answer to what it selects; by default it is the whole
document.  The result is (:file FILE :paths PATHS :truncated BOOL).
PATHS is a vector of (:path PATH :type TYPE), one for every node under
the selection, depth first, selected node first: PATH reads as a
:json-path of a reference and TYPE is \"object\", \"array\", \"string\",
\"number\", \"boolean\" or \"null\".  Neither a value nor the length of a
string is in it.  At most 1000 paths are given, :truncated saying there
were more."
  (let* ((entries (harness-redaction-shape file json-path))
         (paths (cl-remove-if-not (lambda (e) (plist-member e :path)) entries)))
    (list :file (expand-file-name file)
          :paths (apply #'vector paths)
          :truncated (and (cl-some (lambda (e) (plist-get e :truncated)) entries) t))))

(harness-define-module 'secrets
  :doc "Secret references, masking of tool output and the guard against writing placeholders."
  :requires '(store)
  :init #'harness-secrets--init
  :shutdown #'harness-secrets--uninstall)

(provide 'harness-secrets)
;;; harness-secrets.el ends here
