;;; change-review-mail.el --- Emailed patches and mailing-list replies for change-review  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 catvec

;; Author: catvec
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, mail, vc

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Everything a review needs of email: a series of patch mails is a
;; version of a change set, and a reply to it, with the diff quoted and
;; the comments under the lines they are about, is a set of comments.
;;
;; PATCH MAILS.  `change-review-mail-parse-message' reads one mail
;; (as `git format-patch' or `git send-email' wrote it, or as a mail
;; client saved it): its headers, the message that came with the patch
;; and the patch itself.  `change-review-mail-parse-mbox' reads several.
;; `change-review-mail-series' puts mails together into series by the
;; version in their subjects ("[PATCH v2 1/3]") and their threads,
;; `change-review-mail-version' makes a version of a change set of one,
;; and `change-review-mail-import-patches' does all of that for a text
;; and adds the versions to a set (`change-review-mail-make-set' makes
;; one).  A bare unified diff with no mail around it is one version too.
;;
;; THE REPLY FORMAT.  A reviewer on a mailing list answers a patch by
;; quoting the lines the answer is about with "> " and writing the
;; answer under them:
;;
;;   > diff --git a/src/foo.el b/src/foo.el
;;   > @@ -15,4 +15,4 @@ (defun foo ()
;;   >  (setq a15 15)
;;   > -(setq a18 18)
;;   > +(setq a18 'eighteen)
;;
;;   Why eighteen?
;;
;; `change-review-mail-render-comments' writes comments that way, each
;; line of the diff quoted once with the comments under the lines they
;; are about; `change-review-mail-parse-reply' reads such a text back,
;; also when it comes from a mail client: attribution lines, a
;; signature, elisions and the quotes of earlier replies are told from
;; the diff.  `change-review-mail-import-reply' adds what it reads to a
;; set as comments, `change-review-mail-reply-message' writes a whole
;; reply mail and `change-review-mail-compose' opens it for sending.
;; The line grammar is the one a mailing list has used for decades, so a
;; text written by hand and one written by the library read the same.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'qp)
(require 'rfc2047)
(require 'change-review)
(require 'change-review-diff)

(defvar message-sent-hook)
(defvar mail-header-separator)
(declare-function message-mode "message" ())

(defgroup change-review-mail nil
  "Emailed patches and mailing-list replies in change-review."
  :group 'change-review :prefix "change-review-mail-")

(defcustom change-review-mail-fill-column 72
  "Width the text of a comment is filled to in a reply.
A paragraph with a line wider than this is filled, one with none is
left as it was written."
  :type 'natnum)

(defcustom change-review-mail-excerpt-lines 8
  "How many lines of the diff at most a comment read from a reply keeps.
They are the lines quoted just above the comment, the one it is under
last, and make the excerpt of its location."
  :type 'natnum)

(defcustom change-review-mail-attribution-regexps
  '("\\`On .+ wrote:[ \t]*\\'"
    "\\`On .*[0-9].*,\\'"
    "\\`.+ \\(?:writes\\|wrote\\):[ \t]*\\'"
    "\\`-+ *Original Message *-+[ \t]*\\'"
    "\\`My comments on the diff of your branch .*:[ \t]*\\'")
  "Regular expressions for lines of a reply that are no comment.
They name who is quoted, or what the quote is, and a reply is read
without them.  Each is matched against a whole line, trimmed."
  :type '(repeat regexp))

;;;; Reading mail

(defconst change-review-mail--envelope-regexp
  (concat "^From [^ \n]+ +\\(?:[A-Z][a-z][a-z] +\\)?[A-Z][a-z][a-z] +[0-9]+ +"
          "[0-9][0-9]:[0-9][0-9]\\(?::[0-9][0-9]\\)?\\(?: +[-+A-Z0-9]+\\)? +[0-9][0-9][0-9][0-9]")
  "A line that starts a mail in an mbox: \"From \", who, and when.
A mail written by `git format-patch' has the commit for who.")

(defconst change-review-mail--signature-regexp "^-- ?$"
  "The line that starts the signature of a mail.")

(defun change-review-mail--newlines (text)
  "Return TEXT with newlines for line ends."
  (if (string-search "\r" text)
      (replace-regexp-in-string "\r\n?" "\n" text t t)
    text))

(defun change-review-mail--normalize (text)
  "Return TEXT with newlines for line ends, and as characters when it is bytes.
Bytes are read as UTF-8; a mail keeps them until its headers say better
\(`change-review-mail-parse-message')."
  (change-review-mail--newlines
   (if (multibyte-string-p text) text (decode-coding-string text 'utf-8 t))))

(defun change-review-mail--drop-leading-blanks (text)
  "Return TEXT without the blank lines at its start."
  (if (string-match "\\`\\(?:[ \t]*\n\\)+" text) (substring text (match-end 0)) text))

(defun change-review-mail--decode-bytes (bytes coding)
  "Return BYTES as text: UTF-8, or in CODING when they are not UTF-8."
  (let ((text (decode-coding-string bytes 'utf-8 t)))
    (if (and coding (string-match-p "[\x3fff80-\x3fffff]" text))
        (decode-coding-string bytes coding t)
      text)))

(defun change-review-mail--decode-header (value)
  "Return VALUE, a header, with its encoded words (RFC 2047) decoded."
  (if (and (stringp value) (string-search "=?" value))
      (condition-case nil
          (rfc2047-decode-string value)
        (error value))
    value))

(defun change-review-mail--ids (value)
  "Return the message ids, \"<...>\" each, in the header VALUE."
  (let ((pos 0) ids)
    (while (and (stringp value) (string-match "<[^<> \t\n]+>" value pos))
      (push (match-string 0 value) ids)
      (setq pos (match-end 0)))
    (nreverse ids)))

(defun change-review-mail--time (date)
  "Return DATE, a header, as a number of seconds, or nil when it is none."
  (when (and (stringp date) (not (string-blank-p date)))
    (condition-case nil
        (float-time (date-to-time date))
      (error nil))))

(defun change-review-mail--address (string)
  "Return (NAME . EMAIL) for STRING, an address as a header has it.
Either may be nil.  Forms: `Name <a@b>', `\"Name\" <a@b>', `<a@b>',
`a@b' and `a@b (Name)'."
  (let ((string (string-trim (or string ""))))
    (cond
     ((string-match "\\`\\(.*?\\)[ \t]*<\\([^<>]*\\)>" string)
      ;; Both groups before anything else uses the match data.
      (let* ((raw-name (match-string 1 string))
             (raw-email (match-string 2 string))
             (name (string-trim raw-name "[ \t\"']+" "[ \t\"']+"))
             (email (string-trim raw-email)))
        (cons (and (not (string-empty-p name)) (replace-regexp-in-string "\\\\\\(.\\)" "\\1" name))
              (and (not (string-empty-p email)) email))))
     ((string-match "\\`\\([^ \t()]+@[^ \t()]+\\)[ \t]*(\\(.*\\))" string)
      (let ((email (match-string 1 string)) (name (match-string 2 string)))
        (cons (string-trim name) email)))
     ((string-match-p "@" string) (cons nil string))
     ((string-empty-p string) (cons nil nil))
     (t (cons string nil)))))

;;;;; Headers and parts

(defun change-review-mail--header-line-p (line)
  "Return non-nil when LINE starts a header: a field name, then a colon."
  (string-match-p "\\`[!-9;-~]+:\\(?:[ \t]\\|\\'\\)" line))

(defun change-review-mail--split-headers (text)
  "Return (ENVELOPE HEADERS . BODY) for the mail TEXT.
ENVELOPE is the mbox line that starts it, if there is one; HEADERS an
alist of (NAME . VALUE) with lower-case names and unfolded values, in
order; BODY the rest.  A text that does not start with headers has none:
all of it is the BODY."
  (let* ((lines (split-string text "\n"))
         (envelope (when (and lines (string-match-p change-review-mail--envelope-regexp
                                                    (concat (car lines) "\n")))
                     (pop lines)))
         headers)
    (when (and lines (change-review-mail--header-line-p (car lines)))
      (while (and lines (not (string-empty-p (car lines)))
                  (or (change-review-mail--header-line-p (car lines))
                      (and headers (string-match-p "\\`[ \t]" (car lines)))))
        (let ((line (pop lines)))
          (if (string-match-p "\\`[ \t]" line)
              (setcdr (car headers) (concat (cdr (car headers)) " " (string-trim line)))
            (string-match "\\`\\([^:]+\\):[ \t]*" line)
            (push (cons (downcase (match-string 1 line))
                        (string-trim-right (substring line (match-end 0))))
                  headers))))
      (setq headers (nreverse headers))
      ;; The blank line ends the headers; a line that is none does, too.
      (when (and lines (string-empty-p (car lines))) (pop lines)))
    (if headers
        (cons envelope (cons headers (string-join lines "\n")))
      (cons envelope (cons nil (string-join (if envelope lines (split-string text "\n")) "\n"))))))

(defun change-review-mail--parameter (header name)
  "Return the parameter NAME of HEADER, such as `charset' of a Content-Type."
  (when (and (stringp header)
             (string-match (format ";[ \t]*%s[ \t]*=[ \t]*\\(?:\"\\([^\"]*\\)\"\\|\\([^;\" \t]+\\)\\)"
                                   (regexp-quote name))
                           header))
    (or (match-string 1 header) (match-string 2 header))))

(defun change-review-mail--decode-part (body headers bytes-p)
  "Return BODY decoded as the mail HEADERS say: transfer encoding and charset.
BYTES-P is non-nil when BODY was given as bytes, which the charset
turns into characters; text that is characters already is left."
  (let* ((encoding (downcase (or (cdr (assoc "content-transfer-encoding" headers)) "7bit")))
         (charset (change-review-mail--parameter (cdr (assoc "content-type" headers)) "charset"))
         (coding (or (and charset (coding-system-from-name charset)) 'utf-8))
         (decode (lambda (bytes) (decode-coding-string bytes coding t))))
    (pcase (string-trim encoding)
      ("quoted-printable"
       (funcall decode (quoted-printable-decode-string
                        (if (multibyte-string-p body) (encode-coding-string body 'utf-8) body))))
      ("base64"
       (funcall decode (condition-case nil
                           (base64-decode-string
                            (if (multibyte-string-p body) (encode-coding-string body 'utf-8) body))
                         (error ""))))
      (_ (if (and bytes-p (not (multibyte-string-p body))) (funcall decode body) body)))))

(defun change-review-mail--multipart-text (body type boundary bytes-p)
  "Return the text of the parts of BODY, a multipart/TYPE with BOUNDARY.
The `text/plain' parts and the patch parts (`text/x-patch', `text/x-diff')
in order; of an alternative, the first plain part only.  BYTES-P is as
for `change-review-mail--decode-part'."
  (let* ((marker (concat "--" boundary))
         (lines (split-string body "\n"))
         (inside nil)
         parts current)
    (dolist (line lines)
      (cond ((string= (string-trim-right line) marker)
             (when inside (push (nreverse current) parts))
             (setq inside t current nil))
            ((string= (string-trim-right line) (concat marker "--"))
             (when inside (push (nreverse current) parts))
             (setq inside nil current nil))
            (inside (push line current))))
    (when inside (push (nreverse current) parts))
    (let ((texts nil))
      (dolist (part (nreverse parts))
        (let* ((split (change-review-mail--split-headers (string-join part "\n")))
               (headers (cadr split))
               (content (cddr split))
               (content-type (or (cdr (assoc "content-type" headers)) "text/plain"))
               (kind (downcase (car (split-string content-type "[; \t]+" t)))))
          (cond
           ((string-prefix-p "multipart/" kind)
            (when-let* ((inner (change-review-mail--parameter content-type "boundary")))
              (push (change-review-mail--multipart-text content kind inner bytes-p) texts)))
           ((member kind '("text/plain" "text/x-patch" "text/x-diff" "text/x-c" "text/x-csrc"))
            (unless (and (equal type "alternative") texts)
              (push (change-review-mail--decode-part content headers bytes-p) texts))))))
      (string-join (nreverse texts) "\n"))))

(defun change-review-mail--body-text (body headers bytes-p)
  "Return the text of BODY, as the mail HEADERS describe it."
  (let* ((content-type (cdr (assoc "content-type" headers)))
         (kind (and content-type (downcase (car (split-string content-type "[; \t]+" t))))))
    (if (and kind (string-prefix-p "multipart/" kind)
             (change-review-mail--parameter content-type "boundary"))
        (change-review-mail--multipart-text
         body (substring kind (length "multipart/"))
         (change-review-mail--parameter content-type "boundary") bytes-p)
      (change-review-mail--decode-part body headers bytes-p))))

;;;;; The patch in a mail

(defconst change-review-mail--binary-line-regexp
  "\\`\\(?:[A-Za-z][!-~]*\\|literal [0-9]+\\|delta [0-9]+\\)\\'"
  "A line of a binary patch: its data, or what the data is.")

(defun change-review-mail--patch-start (lines)
  "Return the index in LINES, a vector, of the first line of the patch, or nil.
That is the first \"diff --git\" line, else the first \"--- \" line that
a \"+++ \" line follows."
  (let ((count (length lines)) (index 0) git plain)
    (while (and (not git) (< index count))
      (let ((line (aref lines index)))
        (cond ((string-prefix-p "diff --git " line) (setq git index))
              ((and (not plain) (string-prefix-p "--- " line) (< (1+ index) count)
                    (string-prefix-p "+++ " (aref lines (1+ index))))
               (setq plain index))))
      (cl-incf index))
    (or git plain)))

(defun change-review-mail--patch-end (lines start)
  "Return the index in LINES, a vector, just after the patch that starts at START.
It ends before the signature, or before the first line outside a hunk
that is no part of a patch.  A line that looks like the signature inside
a hunk -- a deleted line \"- \" -- is the hunk's: the counts of the
hunk say where it ends."
  (let ((index start) (count (length lines)) (old 0) (new 0) (binary nil) done)
    (while (and (not done) (< index count))
      (let ((line (aref lines index)))
        (cond
         ;; Inside a hunk: its lines, until its counts are used up.
         ((or (> old 0) (> new 0))
          (cond ((string-prefix-p "\\" line))
                ((string-prefix-p "+" line) (cl-decf new))
                ((string-prefix-p "-" line) (cl-decf old))
                ((or (string-prefix-p " " line) (string-empty-p line)) (cl-decf old) (cl-decf new))
                ;; Counts that a mail program spoiled: the line is no part of
                ;; the hunk, but may well start the next thing.
                (t (setq old 0 new 0) (cl-decf index)))
          (setq old (max old 0) new (max new 0)))
         (binary
          (cond ((or (string-empty-p line) (string-match-p change-review-mail--binary-line-regexp line)))
                (t (setq binary nil) (cl-decf index))))
         ((string-match "\\`@@ -[0-9]+\\(?:,\\([0-9]+\\)\\)? \\+[0-9]+\\(?:,\\([0-9]+\\)\\)? @@" line)
          (setq old (if (match-string 1 line) (string-to-number (match-string 1 line)) 1)
                new (if (match-string 2 line) (string-to-number (match-string 2 line)) 1)))
         ((string-match-p change-review-mail--signature-regexp line) (setq done t))
         ((string-prefix-p "GIT binary patch" line) (setq binary t))
         ((string-match-p (concat "\\`\\(?:diff \\|index \\|--- \\|\\+\\+\\+ \\|new file \\|deleted file \\|"
                                  "old mode \\|new mode \\|similarity \\|dissimilarity \\|rename \\|copy \\|"
                                  "Binary files \\|\\\\ \\)")
                          line))
         ;; A blank line inside a patch is followed by more of it.
         ((string-empty-p line)
          (let ((next (1+ index)))
            (while (and (< next count) (string-empty-p (aref lines next))) (cl-incf next))
            (unless (and (< next count)
                         (string-match-p "\\`\\(?:diff \\|--- \\|index \\|@@ \\)" (aref lines next)))
              (setq done t))))
         (t (setq done t))))
      (unless done (cl-incf index)))
    index))

(defun change-review-mail--split-patch (text)
  "Return (BODY PATCH BASE) for TEXT, the body of a mail.
PATCH is the unified diff in it, from its first line to the line before
the signature, nil when there is none.  BODY is what comes before: with
the \"---\" line that parts a message from its diffstat, and that
diffstat, left out when a patch follows; without a patch, TEXT less its
signature.  BASE is the commit of a \"base-commit:\" line that
follows the patch, as `git format-patch --base' writes it."
  (let* ((lines (vconcat (split-string text "\n")))
         (start (change-review-mail--patch-start lines)))
    (if (null start)
        (list (change-review-mail--trim-body
               (string-join (change-review-mail--drop-signature (append lines nil)) "\n"))
              nil nil)
      (let* ((end (change-review-mail--patch-end lines start))
             (before (append (seq-subseq lines 0 start) nil))
             (separator (cl-position-if (lambda (line) (string-match-p "\\`---[ \t]*\\'" line))
                                        before :from-end t))
             (message-lines (if separator (seq-take before separator) before))
             (after (change-review-mail--drop-signature (append (seq-subseq lines end) nil))))
        (list (change-review-mail--trim-body (string-join message-lines "\n"))
              (concat (string-join (append (seq-subseq lines start end) nil) "\n") "\n")
              (cl-some (lambda (line)
                         (and (string-match "\\`base-commit: \\([0-9a-f]\\{7,64\\}\\)[ \t]*\\'" line)
                              (match-string 1 line)))
                       after))))))

(defun change-review-mail--drop-signature (lines)
  "Return LINES without the signature and what follows it."
  (let ((cut (cl-position-if (lambda (line) (string-match-p change-review-mail--signature-regexp line))
                             lines)))
    (if cut (seq-take lines cut) lines)))

(defun change-review-mail--trim-body (text)
  "Return TEXT without blank lines before and after it, and trailing blanks."
  (string-trim (replace-regexp-in-string "[ \t]+$" "" text) "\n+" "[ \t\n]+"))

;;;;; A mail

(defun change-review-mail--header (headers name)
  "Return the first header NAME of HEADERS, an alist, or nil."
  (cdr (assoc name headers)))

(defun change-review-mail-parse-message (text)
  "Return the mail TEXT as a plist.
TEXT is a mail as `git format-patch' writes it, or as a mail client
saves one: an mbox line, headers, a blank line, the message.  A text
with no headers is a message with none.  The plist has
  :from :from-name :from-email   who wrote it, as the header says, and
                                 told apart (encoded words decoded)
  :to :cc :subject               headers, decoded
  :date :time                    the Date header, and as seconds
  :message-id :in-reply-to       message ids, \"<...>\" each; :in-reply-to
                                 the message answered (the first of the
                                 header, else the last of References)
  :references                    the ids of References
  :headers                       every header, an alist of lower-case
                                 names and unfolded values
  :body                          the message: for a patch, the commit
                                 message after its subject line (without
                                 the \"---\" and the diffstat); for a
                                 reply, its text.  Without the signature.
  :patch                         the unified diff the mail holds, from its
                                 first line to the signature, or nil
  :commit                        the commit of the mbox line git wrote
  :base-commit                   the commit of a \"base-commit:\" line
                                 after the patch."
  (let* ((bytes-p (not (multibyte-string-p text)))
         (text (change-review-mail--drop-leading-blanks (change-review-mail--newlines text)))
         (split (change-review-mail--split-headers text))
         (envelope (car split))
         ;; Bytes: the headers are UTF-8 or encoded words, or else in the
         ;; charset of the body, which is whatever its Content-Type says.
         (headers (if bytes-p
                      (let ((coding (when-let* ((charset (change-review-mail--parameter
                                                          (cdr (assoc "content-type" (cadr split)))
                                                          "charset")))
                                      (coding-system-from-name charset))))
                        (mapcar (lambda (header)
                                  (cons (car header) (change-review-mail--decode-bytes (cdr header) coding)))
                                (cadr split)))
                    (cadr split)))
         (content (change-review-mail--body-text (cddr split) headers bytes-p))
         (parts (change-review-mail--split-patch content))
         (from (change-review-mail--decode-header (change-review-mail--header headers "from")))
         (address (change-review-mail--address from))
         (date (change-review-mail--header headers "date"))
         (references (change-review-mail--ids (change-review-mail--header headers "references"))))
    (list :from from
          :from-name (car address)
          :from-email (cdr address)
          :to (change-review-mail--decode-header (change-review-mail--header headers "to"))
          :cc (change-review-mail--decode-header (change-review-mail--header headers "cc"))
          :subject (change-review-mail--decode-header (change-review-mail--header headers "subject"))
          :date date
          :time (change-review-mail--time date)
          :message-id (car (change-review-mail--ids (change-review-mail--header headers "message-id")))
          :in-reply-to (or (car (change-review-mail--ids (change-review-mail--header headers "in-reply-to")))
                           (car (last references)))
          :references references
          :headers headers
          :body (nth 0 parts)
          :patch (nth 1 parts)
          :base-commit (nth 2 parts)
          :commit (and envelope
                       (string-match "\\`From \\([0-9a-f]\\{7,64\\}\\) " envelope)
                       (match-string 1 envelope)))))

(defun change-review-mail-parse-mbox (text)
  "Return the mails in TEXT, as `change-review-mail-parse-message' gives them.
TEXT is an mbox: mails that start with an mbox line, \"From \" and who
and when; \">From \" lines in a mail are unquoted.  Several files of
`git format-patch' put one after the other are one.  A text with no
mbox line is one mail."
  (let* ((bytes-p (not (multibyte-string-p text)))
         (text (change-review-mail--newlines text))
         (starts nil))
    (with-temp-buffer
      ;; Bytes stay bytes, for each mail to be read in its charset.
      (when bytes-p (set-buffer-multibyte nil))
      (insert text)
      (goto-char (point-min))
      (while (re-search-forward change-review-mail--envelope-regexp nil t)
        (let ((start (match-beginning 0)))
          (when (or (= start (point-min))
                    (save-excursion (goto-char start) (forward-line -1) (looking-at-p "^[ \t]*$")))
            (push start starts))))
      (setq starts (nreverse starts))
      (if (null starts)
          (list (change-review-mail-parse-message text))
        (let (mails)
          (cl-loop for (start . rest) on starts
                   for end = (or (car rest) (point-max))
                   do (push (change-review-mail-parse-message
                             (change-review-mail--unquote-from
                              (buffer-substring-no-properties start end)))
                            mails))
          (nreverse mails))))))

(defun change-review-mail--unquote-from (text)
  "Return TEXT, a mail of an mbox, with \">From \" lines unquoted."
  (replace-regexp-in-string "^>\\(>*From \\)" "\\1" text))

;;;; Subjects

(defun change-review-mail-parse-subject (subject)
  "Return what SUBJECT says of the patch, as a plist.
A subject such as \"Re: [RFC PATCH v2 net-next 3/5] area: title\" gives
  :tags     the words in the brackets but the numbers: (\"RFC\" \"PATCH\"
            \"v2\" \"net-next\")
  :kind     \"PATCH\", or \"RFC\" when that is all the tag says, or nil
  :rfc      non-nil with RFC in the tag
  :version  the number of \"v2\", 1 without it
  :index :count   3 and 5; an index of 0 is the cover letter, both nil
            for a single patch
  :reply    non-nil with a \"Re:\" before it
  :title    what follows the tag: \"area: title\"."
  (let ((rest (string-trim (or subject "")))
        (reply nil) tags index count)
    (while (string-match "\\`\\(?:[Rr][Ee]\\|[Ff][Ww][Dd]?\\)\\(?:\\[[0-9]+\\]\\)?:[ \t]*" rest)
      (when (string-match-p "\\`[Rr][Ee]" rest) (setq reply t))
      (setq rest (substring rest (match-end 0))))
    (while (string-match "\\`\\[\\([^]]*\\)\\][ \t]*" rest)
      ;; The words are looked at with `string-match' too: take what is
      ;; needed of this match first.
      (let* ((end (match-end 0))
             (words (split-string (match-string 1 rest) "[ \t,]+" t)))
        (dolist (word words)
          (if (string-match "\\`\\([0-9]+\\)/\\([0-9]+\\)\\'" word)
              (setq index (string-to-number (match-string 1 word))
                    count (string-to-number (match-string 2 word)))
            (push word tags)))
        (setq rest (substring rest end))))
    (setq tags (nreverse tags))
    (let* ((upper (mapcar #'upcase tags))
           (patch (member "PATCH" upper))
           (rfc (and (member "RFC" upper) t))
           (version (or (cl-some (lambda (tag)
                                   (and (string-match "\\`[vV]\\([0-9]+\\)\\'" tag)
                                        (string-to-number (match-string 1 tag))))
                                 tags)
                        1)))
      (list :tags tags
            :kind (cond (patch "PATCH") (rfc "RFC"))
            :rfc rfc :version version :index index :count count
            :reply reply :title (string-trim rest)))))

(defun change-review-mail--cover-p (message)
  "Return non-nil when MESSAGE is the cover letter of a series."
  (let ((info (change-review-mail-parse-subject (plist-get message :subject))))
    (and (not (plist-get info :reply))
         (eql 0 (plist-get info :index))
         (not (plist-get message :patch)))))

(defun change-review-mail--patch-p (message)
  "Return non-nil when MESSAGE is a patch: no reply, and it holds a diff."
  (and (plist-get message :patch)
       (not (plist-get (change-review-mail-parse-subject (plist-get message :subject)) :reply))))

;;;; Series

(defun change-review-mail--thread-root (message by-id)
  "Return the id that names the thread MESSAGE is in.
That is the first id of its References, else the id of the message its
In-Reply-To chain leads to among BY-ID, a table of ids to messages, else
its own id; nil for a message with none."
  (or (car (plist-get message :references))
      (let ((current message) (seen nil))
        (while-let ((parent (plist-get current :in-reply-to))
                    (next (and (not (member parent seen)) (gethash parent by-id))))
          (push parent seen)
          (setq current next))
        (or (plist-get current :in-reply-to) (plist-get current :message-id)))))

(defun change-review-mail--first-path (patch)
  "Return the path of the first file of PATCH, a unified diff, or nil."
  (cond ((and patch (string-match "^diff --git a/\\(.+?\\) b/\\(.+\\)$" patch)) (match-string 2 patch))
        ((and patch (string-match "^\\+\\+\\+ b/\\(.+\\)$" patch)) (match-string 1 patch))
        ((and patch (string-match "^\\+\\+\\+ \\([^\t\n]+\\)" patch)) (match-string 1 patch))))

(defun change-review-mail--series-title (cover patches)
  "Return the title of a series with COVER (a message or nil) and PATCHES."
  (let ((titled (lambda (message)
                  (let ((title (plist-get (change-review-mail-parse-subject
                                           (plist-get message :subject))
                                          :title)))
                    (and (not (string-empty-p title))
                         (not (string-match-p "\\*\\*\\* SUBJECT HERE \\*\\*\\*" title))
                         title)))))
    (or (and cover (funcall titled cover))
        (and patches (funcall titled (car patches)))
        (and patches (change-review-mail--first-path (plist-get (car patches) :patch)))
        "")))

(defun change-review-mail--series-plist (version cover patches)
  "Return the series of VERSION made of COVER and PATCHES, mails."
  (let* ((head (or cover (car patches)))
         (patches (cl-stable-sort
                   (copy-sequence patches)
                   (lambda (a b)
                     (< (or (plist-get (change-review-mail-parse-subject (plist-get a :subject)) :index) 1)
                        (or (plist-get (change-review-mail-parse-subject (plist-get b :subject)) :index) 1)))))
         (address (change-review-mail--address (plist-get head :from))))
    (list :title (change-review-mail--series-title cover patches)
          :version version
          :message-id (plist-get head :message-id)
          :cover cover
          :patches patches
          :author (change-review-user (or (car address) (cdr address)) (cdr address))
          :time (plist-get head :time))))

(defun change-review-mail-series (messages)
  "Return the series of patches MESSAGES, mails, make up, oldest version first.
A series is a plist
  :title :version      the title of the cover letter, else of the first
                       patch, and the version of the tag (\"[PATCH v2]\")
  :message-id          the id of the cover letter, else of the first patch
  :cover               the cover letter, a mail, or nil
  :patches             the mails that hold the patches, in order
  :author :time        who sent it, a `change-review-author', and when.
The mails of one series have one version and one thread: the same first
id in their References, so a v2 sent as a reply to the v1 is another
series, as one sent on its own is.  A reply, and any mail that is no
patch and no cover letter, belongs to none."
  (let ((by-id (make-hash-table :test 'equal))
        (roots (make-hash-table :test 'eq))
        (replied-to (make-hash-table :test 'equal))
        (groups nil))
    (dolist (message messages)
      (when-let* ((id (plist-get message :message-id)))
        (puthash id message by-id)))
    (dolist (message messages)
      (let ((root (change-review-mail--thread-root message by-id)))
        (puthash message root roots)
        (unless (equal root (plist-get message :message-id))
          (puthash root t replied-to))))
    (dolist (message messages)
      (let ((cover (change-review-mail--cover-p message)))
        (when (or cover (change-review-mail--patch-p message))
          (let* ((info (change-review-mail-parse-subject (plist-get message :subject)))
                 (version (plist-get info :version))
                 (root (gethash message roots))
                 (generation 0)
                 (group nil))
            ;; A numbered mail that starts a thread nobody joined was sent
            ;; with no threading (`git send-email --no-thread'): the mails
            ;; of one sender and version are one series.
            (when (and root (equal root (plist-get message :message-id))
                       (not (gethash root replied-to))
                       (or (eql 0 (plist-get info :index)) (> (or (plist-get info :count) 0) 1)))
              (setq root (list 'unthreaded (plist-get message :from-email))))
            ;; The same place in a series met twice in one thread starts the
            ;; next series of that version: mails with no ids cannot be told
            ;; apart otherwise.
            (while (and (setq group (assoc (list version root generation) groups))
                        (cl-some (lambda (other)
                                   (and (eql (plist-get (change-review-mail-parse-subject
                                                         (plist-get other :subject))
                                                        :index)
                                             (plist-get info :index))
                                        (eq (and (change-review-mail--cover-p other) t)
                                            (and cover t))))
                                 (cdr group)))
              (cl-incf generation))
            (if group
                (setcdr group (append (cdr group) (list message)))
              (push (cons (list version root generation) (list message)) groups))))))
    (let ((series (mapcar
                   (lambda (group)
                     (let* ((mails (cdr group))
                            (cover (cl-find-if #'change-review-mail--cover-p mails))
                            (patches (cl-remove-if #'change-review-mail--cover-p mails)))
                       (change-review-mail--series-plist (car (car group)) cover patches)))
                   (nreverse groups))))
      (cl-stable-sort series
                      (lambda (a b)
                        (let ((va (plist-get a :version)) (vb (plist-get b :version)))
                          (or (< va vb)
                              (and (= va vb) (< (or (plist-get a :time) 0)
                                                (or (plist-get b :time) 0))))))))))

;;;; Versions

(defun change-review-mail--patch-meta (patch index)
  "Return the plist that describes PATCH, a mail, as patch INDEX of its series."
  (let ((info (change-review-mail-parse-subject (plist-get patch :subject))))
    (change-review--plist :index index
                          :title (plist-get info :title)
                          :subject (plist-get patch :subject)
                          :message-id (plist-get patch :message-id)
                          :commit (plist-get patch :commit)
                          :body (plist-get patch :body))))

(defun change-review-mail-version (series)
  "Return the version of a change set that the mail SERIES makes.
Its id is the message id of the cover letter, else of the first patch
\(the hash of the patches when the mails have none).  It is called vN
after the version of the tag, takes its time and its author from the
cover letter, or the first patch, and has the cover letter's text for
its description.  Its files are those of all the patches, in order; a
series of several patches marks each file with the patch it is in
\(`change-review-file-patch-id', the index of the patch), so one path
can be there once per patch.  The meta of the version has the
`:patches', a plist of each (:index :title :subject :message-id :commit
:body), and `:subject', the subject of the cover letter or first patch."
  (let* ((cover (plist-get series :cover))
         (patches (plist-get series :patches))
         (head (or cover (car patches)))
         (several (cdr patches))
         (position 0)
         files metas)
    (dolist (patch patches)
      (cl-incf position)
      (let* ((info (change-review-mail-parse-subject (plist-get patch :subject)))
             (index (or (plist-get info :index) position)))
        (dolist (file (change-review-diff-parse (plist-get patch :patch)))
          (when several (setf (change-review-file-patch-id file) index))
          (push file files))
        (push (change-review-mail--patch-meta patch index) metas)))
    (setq files (nreverse files) metas (nreverse metas))
    (let* ((last-patch (car (last patches)))
           (title (plist-get series :title))
           (text (mapconcat (lambda (patch) (or (plist-get patch :patch) "")) patches "")))
      (change-review-make-version
       :id (or (plist-get series :message-id)
               (change-review-stable-id "v" title (secure-hash 'sha1 text)))
       :label (format "v%d" (plist-get series :version))
       :time (plist-get series :time)
       :author (plist-get series :author)
       :title title
       :description (let ((body (or (and cover (plist-get cover :body))
                                    (and patches (plist-get (car patches) :body)))))
                      (and body (not (string-empty-p body)) body))
       :base (or (plist-get last-patch :base-commit) (plist-get cover :base-commit))
       :tip (or (plist-get last-patch :commit) (plist-get cover :commit))
       :files files
       :meta (change-review--plist :series t
                                   :subject (plist-get head :subject)
                                   :patches metas)))))

(defun change-review-mail--bare-message (text)
  "Return a mail for TEXT, a unified diff with no mail around it, or nil."
  (let ((message (change-review-mail-parse-message text)))
    (and (plist-get message :patch) (null (plist-get message :headers)) message)))

(defun change-review-mail--import (set text)
  "Add the versions the patches in TEXT make to SET, or a set it makes.
Return (SET . VERSIONS): the set and the versions it has for TEXT."
  (let* ((messages (change-review-mail-parse-mbox text))
         (bare (and (null (cdr messages)) (change-review-mail--bare-message text)))
         (series (change-review-mail-series (if bare (list bare) messages)))
         (versions (mapcar #'change-review-mail-version series)))
    (unless versions
      (signal 'change-review-error (list "No patch in that text")))
    (let ((set (or set
                   (change-review-make-set
                    :id (change-review-stable-id "s" (change-review-version-id (car versions)))
                    :title (change-review-version-title (car versions))))))
      (cons set (mapcar (lambda (version) (change-review-add-version set version)) versions)))))

(defun change-review-mail-import-patches (set text)
  "Add the versions the patches in TEXT make to SET; return them.
TEXT is an mbox, one patch mail, several files of `git format-patch'
put one after the other, or a unified diff with no mail around it,
which is one version, titled by its first file.  Each series in it
\(`change-review-mail-series') becomes a version
\(`change-review-mail-version'), added oldest first.  Importing a text
again adds nothing: a version of that id is there.  The result is the
versions SET has for TEXT, in that order.  Signal `change-review-error'
for a text with no patch in it.  SET nil makes a set for them; see
`change-review-mail-make-set' to get hold of it."
  (cdr (change-review-mail--import set text)))

(defun change-review-mail-make-set (text)
  "Return a new change set whose versions are the patches in TEXT.
The set is titled by the first series; see `change-review-mail-import-patches'
for what TEXT may be."
  (car (change-review-mail--import nil text)))

(defun change-review-mail-make-set-from-file (file)
  "Return a new change set of the patches in FILE, an mbox or a patch.
The file is read as bytes, so the charsets of its mails are honored."
  (change-review-mail-make-set
   (with-temp-buffer
     (set-buffer-multibyte nil)
     (insert-file-contents-literally file)
     (buffer-string))))

;;;; Writing a reply

(defconst change-review-mail--quote-prefix-regexp "\\`\\(?:>[ \t]?\\)+"
  "What starts a line of a comment that quotes: its \">\"s and the blank after.")

(defun change-review-mail--fill-lines (lines)
  "Return LINES, text of a comment, as one string, filled if it needs to be.
It is when a line is wider than `change-review-mail-fill-column' and
the text is no code, every line of it indented."
  (let ((text (string-join lines "\n")))
    (if (or (cl-every (lambda (line) (string-match-p "\\`\\(?:    \\|\t\\)" line)) lines)
            (cl-notany (lambda (line) (> (string-width line) change-review-mail-fill-column))
                       lines))
        text
      (with-temp-buffer
        (insert text)
        (let ((fill-column change-review-mail-fill-column) (adaptive-fill-mode nil))
          (fill-region (point-min) (point-max)))
        (string-trim-right (buffer-string))))))

(defun change-review-mail--fill-quote-line (line)
  "Return LINE, a line of a comment that quotes, cut to the fill column if need be.
Each piece of it starts as the line does, with the same \">\"s."
  (if (and (> (string-width line) change-review-mail-fill-column)
           (string-match change-review-mail--quote-prefix-regexp line))
      (with-temp-buffer
        (insert line)
        (let ((fill-column change-review-mail-fill-column)
              (adaptive-fill-mode nil)
              (fill-prefix (match-string 0 line)))
          (fill-region (point-min) (point-max)))
        (string-trim-right (buffer-string)))
    line))

(defun change-review-mail--fill-paragraph (paragraph)
  "Return PARAGRAPH, lines of a comment, filled if it needs to be.
It is when a line is wider than `change-review-mail-fill-column' and
the paragraph is no code, every line of it indented.  The lines that
quote, those that start with \">\", are kept as they are, each cut to
the fill column on its own if it is too wide, so that a quote is never
joined to the lines around it or to the quote's own."
  (let ((runs nil))
    ;; Runs of lines: (QUOTES . LINES), in reverse.
    (dolist (line (split-string paragraph "\n"))
      (let ((quotes (string-prefix-p ">" line)))
        (if (and runs (eq (car (car runs)) quotes))
            (push line (cdr (car runs)))
          (push (cons quotes (list line)) runs))))
    (mapconcat (lambda (run)
                 (let ((lines (reverse (cdr run))))
                   (if (car run)
                       (mapconcat #'change-review-mail--fill-quote-line lines "\n")
                     (change-review-mail--fill-lines lines))))
               (nreverse runs) "\n")))

(defun change-review-mail--comment-text (text)
  "Return TEXT, a comment, as a reply writes it.
It is trimmed and filled (`change-review-mail-fill-column'), its
paragraphs a line apart; a line that starts with \">\", which would
read as the quote, gets a space before it."
  (replace-regexp-in-string
   "^>" " >"
   (mapconcat #'change-review-mail--fill-paragraph
              (split-string (string-trim text) "\n\\(?:[ \t]*\n\\)+" t)
              "\n\n")
   t t))

(defun change-review-mail--header-line (location)
  "Return the \"diff --git\" line that opens the quote of LOCATION's file."
  (let ((file (change-review-location-file location)))
    (format "diff --git a/%s b/%s" (or (change-review-location-old-file location) file) file)))

(defun change-review-mail--comment-location (set comment)
  "Return where COMMENT is: its own location, else its thread's, else nil."
  (or (change-review-comment-location comment)
      (when-let* ((found (change-review-find-comment set (change-review-comment-id comment))))
        (change-review-thread-location (car found)))))

(defun change-review-mail--line-key (line)
  "Return the key of LINE, (KIND TEXT OLD NEW): no two lines of a diff share it.
The numbers say where in the diff the line is, new side first, old side
next; a line that marks a missing newline comes before the line whose
numbers it shares."
  (list (nth 3 line) (nth 2 line) (if (eq (car line) ?\\) 0 1) (car line)))

(defun change-review-mail--key< (a b)
  "Return non-nil when the line key A comes before B in a diff."
  (cl-loop for x in a for y in b
           when (/= x y) return (< x y)))

(defun change-review-mail--marker-key-p (key)
  "Return non-nil when KEY is the key of a line that marks a missing newline."
  (eq (nth 3 key) ?\\))

(defun change-review-mail--excerpt-heading (excerpt)
  "Return what the hunk header in EXCERPT has after its numbers."
  (if (string-match "\\`@@ [^@]*@@\\(.*\\)$" excerpt) (match-string 1 excerpt) ""))

(defvar change-review-mail--seen nil
  "While a reply is written: a table of the threads it has a comment of.")

(defun change-review-mail--first-in-thread-p (set comment)
  "Return non-nil the first time it is asked of a comment of COMMENT's thread.
Reply writing keeps the table (`change-review-mail--seen')."
  (let* ((thread (car (change-review-find-comment set (change-review-comment-id comment))))
         (id (if thread (change-review-thread-id thread) (change-review-comment-id comment))))
    (unless (gethash id change-review-mail--seen)
      (puthash id t change-review-mail--seen)
      t)))

(defun change-review-mail--earlier-text (set comment)
  "Return the earlier messages of COMMENT's thread, as a block of text, or nil.
That is every comment of the thread before COMMENT, one entry each --
the author's name, a colon and the text, the lines it goes on to
indented -- under a line that says what they are."
  (when-let* ((found (change-review-find-comment set (change-review-comment-id comment)))
              (thread (car found))
              (position (cl-position (change-review-comment-id comment)
                                     (change-review-thread-comments thread)
                                     :key #'change-review-comment-id :test #'equal)))
    (when (> position 0)
      (concat
       "Earlier in this thread:\n"
       (mapconcat
        (lambda (earlier)
          (let ((lines (split-string (string-trim (change-review-comment-body earlier)) "\n")))
            (concat "  " (change-review-author-label (change-review-comment-author earlier)) ": "
                    (car lines)
                    (mapconcat (lambda (l) (concat "\n    " l)) (cdr lines) ""))))
        (seq-take (change-review-thread-comments thread) position) "\n")))))

(defun change-review-mail--item (set comment)
  "Return the description of COMMENT of SET that a reply is laid out from.
A plist: :comment, :location, :lines (the lines of its excerpt as
`change-review-diff-excerpt-lines' gives them, nil without an excerpt),
:heading, and :prefix, the \"On line N: \" the text starts with when the
excerpt does not end on the line the comment is on."
  (let* ((location (change-review-mail--comment-location set comment))
         (excerpt (and location (change-review-location-excerpt location)))
         (lines (and excerpt
                     (let ((lines (change-review-diff-excerpt-lines excerpt)))
                       ;; An excerpt with no header cannot be put in place.
                       (and (cl-every (lambda (l) (and (nth 2 l) (nth 3 l))) lines) lines))))
         (target (cl-find-if-not (lambda (l) (eq (car l) ?\\)) lines :from-end t))
         (side (and location (change-review-location-side location)))
         (want (and location (or (change-review-location-end-line location)
                                 (change-review-location-line location))))
         (exact (and target want (eql want (change-review-diff-line-number target side)))))
    (list :comment comment :location location
          :lines (and target lines)
          :heading (and excerpt (change-review-mail--excerpt-heading excerpt))
          :prefix (and want (not exact)
                       (format "On line %d%s: " want (if (eq side 'old) " of the merge base" ""))))))

(defun change-review-mail--comment-block (set item history markers)
  "Return the text of the comment of ITEM, a description of it.
It is the comment's text, under the earlier messages of its thread when
HISTORY and it is the first of its thread in the reply, and above a
line MARKERS, a function of the comment, gives."
  (let* ((comment (plist-get item :comment))
         (text (change-review-mail--comment-text
                (concat (plist-get item :prefix) (change-review-comment-body comment))))
         (first (change-review-mail--first-in-thread-p set comment))
         (earlier (and history first (change-review-mail--earlier-text set comment)))
         (marker (and markers (funcall markers comment))))
    (concat (and earlier (concat earlier "\n\n"))
            text
            (and marker (not (string-empty-p marker)) (concat "\n" marker)))))

(defun change-review-mail--runs (items)
  "Return the quote that ITEMS, comments on one file, need.
The result is (RUNS TARGETS LINES HEADINGS).  The excerpts of ITEMS are
put together, each line once; a run is lines that follow each other in
the diff, a list of line keys (`change-review-mail--line-key').  TARGETS
is a table of the key of the line a comment goes under to the items that
go there, LINES one of each key to its line, and HEADINGS one of the key
of the first line of a run to the hunk heading it has."
  (let ((table (make-hash-table :test 'equal))
        (next (make-hash-table :test 'equal))
        (headings (make-hash-table :test 'equal))
        (targets (make-hash-table :test 'equal))
        (ends nil))
    (dolist (item items)
      (let* ((lines (plist-get item :lines))
             (keys (mapcar #'change-review-mail--line-key lines))
             (target (cl-find-if-not (lambda (l) (eq (car l) ?\\)) lines :from-end t)))
        (cl-mapc (lambda (key line) (puthash key line table)) keys lines)
        (cl-loop for (a b) on keys while b do (puthash a b next))
        (unless (gethash (car keys) headings)
          (puthash (car keys) (plist-get item :heading) headings))
        (push (cons (change-review-mail--line-key target) item) ends)))
    ;; A comment goes after the line that marks a missing newline, too.
    (dolist (end (nreverse ends))
      (let* ((key (car end))
             (after (gethash key next))
             (key (if (and after (change-review-mail--marker-key-p after)) after key)))
        (puthash key (append (gethash key targets) (list (cdr end))) targets)))
    (let ((runs nil) (run nil) (previous nil))
      (dolist (key (sort (hash-table-keys table) #'change-review-mail--key<))
        (if (and previous (equal (gethash previous next) key))
            (push key run)
          (when run (push (nreverse run) runs))
          (setq run (list key)))
        (setq previous key))
      (when run (push (nreverse run) runs))
      (list (nreverse runs) targets table headings))))

(defun change-review-mail--group-blocks (set items history markers)
  "Return the blocks of a reply for ITEMS, descriptions of comments on one file.
Each block is (quote . LINES) or (text . STRING), reversed: the last
first.  The comments on the file as a whole come first; then the lines of
the excerpts, put together (`change-review-mail--runs'), each run opened
by a hunk header, the comments under the lines they are about."
  (let ((blocks nil))
    (dolist (item (cl-remove-if (lambda (i) (plist-get i :lines)) items))
      (push (cons 'text (change-review-mail--comment-block set item history markers)) blocks))
    (when-let* ((located (cl-remove-if-not (lambda (i) (plist-get i :lines)) items)))
      (pcase-let ((`(,runs ,targets ,table ,headings) (change-review-mail--runs located)))
        (dolist (run runs)
          (let ((quoted (list (change-review-diff--excerpt-header
                               (list :heading (gethash (car run) headings))
                               (mapcar (lambda (key) (gethash key table)) run)))))
            (dolist (key run)
              (let ((line (gethash key table)))
                (push (concat (char-to-string (car line)) (nth 1 line)) quoted)
                (when-let* ((here (gethash key targets)))
                  (push (cons 'quote (nreverse quoted)) blocks)
                  (setq quoted nil)
                  (dolist (item here)
                    (push (cons 'text (change-review-mail--comment-block set item history markers))
                          blocks)))))
            (when quoted (push (cons 'quote (nreverse quoted)) blocks))))))
    blocks))

(defun change-review-mail--file-rank (set patch file)
  "Return where FILE of PATCH is among the files of SET's newest version."
  (let ((files (and (change-review-latest-version set)
                    (change-review-version-files (change-review-latest-version set)))))
    (or (cl-position-if (lambda (f) (and (equal (change-review-file-path f) file)
                                         (equal (change-review-file-patch-id f) patch)))
                        files)
        (cl-position-if (lambda (f) (equal (change-review-file-path f) file)) files)
        most-positive-fixnum)))

(defun change-review-mail--patch-line (set patch)
  "Return the line that names patch number PATCH of the series of SET."
  (let* ((version (change-review-latest-version set))
         (patches (plist-get (and version (change-review-version-meta version)) :patches))
         (entry (cl-find patch patches :key (lambda (p) (plist-get p :index)))))
    (format "[PATCH %d%s]%s" patch
            (if patches (format "/%d" (length patches)) "")
            (if-let* ((title (plist-get entry :title))) (concat " " title) ""))))

(defun change-review-mail--join-blocks (blocks)
  "Return BLOCKS, (quote . LINES) and (text . STRING), as the text of a reply.
Quoted lines get \"> \" before them; a blank line parts the blocks, but
for two quotes in a row, which are one quote."
  (let ((out nil) (previous nil))
    (dolist (block blocks)
      (when (and previous (not (and (eq previous 'quote) (eq (car block) 'quote))))
        (push "" out))
      (push (if (eq (car block) 'quote)
                (mapconcat (lambda (line) (concat "> " line)) (cdr block) "\n")
              (cdr block))
            out)
      (setq previous (car block)))
    (if out (concat (string-join (nreverse out) "\n") "\n") "")))

(cl-defun change-review-mail-render-comments (set comments &key attribution history markers)
  "Return COMMENTS, comments of SET, written as a reply to the patch.
The diff is quoted with \"> \" and each comment goes under the line it
is about, as a reviewer on a mailing list answers.  The files come in
the order of SET's newest version, each opened by its \"diff --git\"
line; each line of the diff is quoted once, a hunk header opening each
run of lines, and several comments under one line follow one another.  A
comment on a line that the quote ends before says which line it means,
\"On line 12: \" (\"On line 3 of the merge base: \" for a line of the old
file).  A comment on a file as a whole goes right under its first line;
one on the change as a whole, with no location, comes first of all,
quoting nothing.  Text is filled to `change-review-mail-fill-column'.

ATTRIBUTION, a line, goes before the first quote.  With HISTORY the
earlier messages of a thread come before the first of its comments the
reply has, under \"Earlier in this thread:\"; such a text is for reading,
not for reading back.  MARKERS, a function of a comment, gives a line to
put right after it, or nil.

The text is what a reply written by hand is, but for the hunk headers,
which count all the lines quoted in a run."
  (let* ((change-review-mail--seen (make-hash-table :test 'equal))
         (items (mapcar (lambda (c) (change-review-mail--item set c)) comments))
         (filed-p (lambda (i) (let ((loc (plist-get i :location)))
                                (and loc (change-review-location-file loc) t))))
         (groups nil)
         (blocks nil))
    ;; Comments on the change as a whole first.
    (dolist (item (cl-remove-if filed-p items))
      (push (cons 'text (change-review-mail--comment-block set item history markers)) blocks))
    (setq blocks (nreverse blocks))
    ;; A group for each file of each patch and revision.
    (dolist (item (cl-remove-if-not filed-p items))
      (let* ((loc (plist-get item :location))
             (key (list (change-review-location-patch loc)
                        (change-review-location-file loc)
                        (change-review-comment-revision (plist-get item :comment))))
             (cell (assoc key groups)))
        (if cell
            (setcdr cell (append (cdr cell) (list item)))
          (setq groups (append groups (list (cons key (list item))))))))
    (setq groups (cl-stable-sort
                  groups
                  (lambda (a b)
                    (< (change-review-mail--file-rank set (nth 0 (car a)) (nth 1 (car a)))
                       (change-review-mail--file-rank set (nth 0 (car b)) (nth 1 (car b)))))))
    (let ((patches (delete-dups (delq nil (mapcar (lambda (g) (nth 0 (car g))) groups))))
          (previous 'none)
          (quoted nil))
      (dolist (group groups)
        (let ((patch (nth 0 (car group))))
          (when (and (cdr patches) patch (not (equal patch previous)))
            (push (cons 'quote (list (change-review-mail--patch-line set patch))) quoted))
          (setq previous patch))
        (let ((items (cdr group)))
          (push (cons 'quote (list (change-review-mail--header-line
                                    (plist-get (car items) :location))))
                quoted)
          (setq quoted (append (change-review-mail--group-blocks set items history markers)
                               quoted))))
      (when (and quoted attribution)
        (setq blocks (append blocks (list (cons 'text attribution)))))
      (setq blocks (append blocks (nreverse quoted))))
    (change-review-mail--join-blocks blocks)))

;;;; Reading a reply

(defconst change-review-mail--hunk-regexp
  "\\`@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@\\(.*\\)"
  "A hunk's header, quoted, without the \"> \".
Its groups: where the hunk starts in the old file and how many lines it
has there, the same in the new file, and what follows (git's heading).")

(defconst change-review-mail--on-line-regexp
  "\\`On line \\([0-9]+\\)\\( of the merge base\\)?: ?"
  "What a comment on a line the quote does not hold starts with.
The comment goes under the nearest line the quote has, and this says
which line it is about; the old file's is \"of the merge base\".")

(defconst change-review-mail--diff-header-regexp
  (concat "\\`\\(?:index \\|--- \\|\\+\\+\\+ \\|new file mode\\|deleted file mode\\|old mode\\|"
          "new mode\\|similarity index\\|dissimilarity index\\|rename \\|copy \\|"
          "Binary files \\|GIT binary patch\\)")
  "A quoted line of a diff's header, between its \"diff --git\" line and a hunk.")

(defconst change-review-mail--elision-regexp
  "\\`\\[\\(?:\\.\\.\\.\\|…\\|snip\\|SNIP\\)\\]\\'"
  "A line that stands for lines left out of a quote.")

(defconst change-review-mail--patch-marker-regexp
  "\\`\\[[^]]*PATCH[^]]* \\([0-9]+\\)/[0-9]+\\]"
  "A quoted line that names the patch of a series the lines after it are of.")

(defun change-review-mail--header-paths (line)
  "Return (OLD . NEW) for LINE, a \"diff --git a/OLD b/NEW\" line.
The diff library reads the line (`change-review-diff--git-line-paths'):
paths with spaces and quoted paths as git writes them, and two paths
that cannot be told apart taken to be one, the common case.  Nil for a
line that is none."
  (when (string-match "\\`diff --git \\(.*\\)\\'" line)
    (when-let* ((pair (change-review-diff--git-line-paths (match-string 1 line))))
      (let ((prefixes (or (change-review-diff--prefixes pair) (cons "a/" "b/"))))
        (cons (change-review-diff--strip (car pair) (car prefixes))
              (change-review-diff--strip (cdr pair) (cdr prefixes)))))))

(defun change-review-mail--excerpt-from (lines heading)
  "Return the excerpt that LINES make, with the hunk heading HEADING.
LINES are (KIND TEXT OLD NEW), oldest first, as
`change-review-diff-excerpt-lines' gives them.  The hunk header counts
just those lines.  Nil when LINES are none or a number is not known."
  (when (and lines (cl-every (lambda (l) (and (nth 2 l) (nth 3 l))) lines))
    (concat (change-review-diff--excerpt-header (list :heading heading) lines)
            (mapconcat (lambda (l) (concat "\n" (char-to-string (car l)) (nth 1 l))) lines ""))))

(defun change-review-mail--attribution-p (line)
  "Return non-nil when LINE, text of a reply, only says who is quoted."
  (let ((line (string-trim line)))
    (cl-some (lambda (regexp) (string-match-p regexp line))
             change-review-mail-attribution-regexps)))

(defun change-review-mail--block-result (state lines)
  "Return the comment that LINES, text of a reply, make, or nil.
STATE is the part of the quote the text was under, a plist: :file,
:path, :old-path, :patch, :last (what the last quoted line was),
:recent (the lines quoted above it, newest first), :heading and :prose."
  (let ((text (string-trim (string-join (reverse lines) "\n"))))
    (unless (string-empty-p text)
      (let* ((last (plist-get state :last))
             (entry (and (eq (car last) 'content) (cadr last)))
             (known (and entry (nth 2 entry) (nth 3 entry)))
             (side (if (and entry (eq (car entry) ?-)) 'old 'new))
             (line (and known (if (eq side 'old) (nth 2 entry) (nth 3 entry))))
             (excerpt (and known
                           (change-review-mail--excerpt-from
                            (reverse (plist-get state :recent)) (plist-get state :heading))))
             (approx nil))
        (when (string-match change-review-mail--on-line-regexp text)
          (setq line (string-to-number (match-string 1 text))
                side (if (match-string 2 text) 'old 'new)
                approx t
                text (string-trim (substring text (match-end 0)))))
        (list :file (plist-get state :file)
              :path (plist-get state :path)
              :old-path (plist-get state :old-path)
              :patch (plist-get state :patch)
              :side side :line line :end-line nil
              :excerpt excerpt
              :body text
              :approx approx
              :prose (plist-get state :prose))))))

(cl-defun change-review-mail-parse-reply (text &key split)
  "Return the comments that the reply TEXT makes, in order, as plists.
TEXT is a review the way a mailing list writes one: the lines of the
diff quoted with \"> \" and the comments under them.  A line that
starts with \">\" is the diff; \"diff --git a/X b/Y\" opens a file, a
hunk header \"@@ -a,b +c,d @@\" the numbers, which go on across the
comments; other lines are context, added (+) or removed (-).  Lines that
are not are told from them and left out: a quote of earlier replies
\(\"> >\"), of text that is no diff, a line that says who is quoted
\(`change-review-mail-attribution-regexps'), \"[...]\", the signature.  A
comment is the text under the last quoted line, to the next quote; with
SPLIT a blank line ends it too, so a paragraph is a comment.

Each plist has
  :file :path :old-path   the \"diff --git\" line the comment is under,
                          the path it names, and the one before a rename
                          (nil when the same); all nil for a comment
                          before any file, which is on the change
  :side :line :end-line   `new' or `old' and the line of the last quoted
                          line, `old' for a removed one; nil for the
                          file as a whole (:end-line is always nil)
  :excerpt                the diff lines up to that one, at most
                          `change-review-mail-excerpt-lines', as the
                          excerpt of a `change-review-location' with the
                          hunk header counting just them; or nil
  :body                   the comment, trimmed.  \"On line 57: \" (or \"On
                          line 3 of the merge base: \") before it is
                          taken off and gives :side and :line
  :approx                 non-nil with that prefix
  :patch                  the number of the patch of a series the quote
                          named (\"> [PATCH 2/3] title\"), or nil
  :prose                  quoted lines before it that are no diff, which
                          tell what it answers."
  (let ((lines (split-string (change-review-mail--normalize text) "\n"))
        (file nil) (path nil) (old-path nil) (hunk nil) (heading "")
        (old nil) (new nil) (recent nil) (last nil) (patch nil)
        (block nil) (block-lines nil) (prose nil) (ignoring nil) (blocks nil))
    (cl-labels
        ((finish ()
           (when block
             (when-let* ((result (change-review-mail--block-result block block-lines)))
               (push result blocks))
             (setq block nil block-lines nil)))
         (start ()
           (setq block (list :file file :path path :old-path old-path :patch patch :last last
                             :recent (seq-take recent change-review-mail-excerpt-lines)
                             :heading heading :prose (reverse prose))
                 prose nil))
         (blank ()
           (when block
             (if split (finish) (push "" block-lines))))
         (prose-line (content)
           (push content prose)
           (setq ignoring t))
         (content-line (content)
           (let ((kind (if (string-empty-p content) ?\s (aref content 0)))
                 (text (if (string-empty-p content) "" (substring content 1))))
             (if (not (memq kind '(?\s ?+ ?- ?\\)))
                 (prose-line content)
               (let ((entry (list kind text old new)))
                 (push entry recent)
                 (setq recent (seq-take recent 32))
                 (unless (eq kind ?\\) (setq last (list 'content entry)))
                 (when (and old new)
                   (pcase kind
                     (?\s (cl-incf old) (cl-incf new))
                     (?- (cl-incf old))
                     (?+ (cl-incf new))))))))
         (quoted (line)
           (finish)
           (let ((content (substring line (if (string-prefix-p "> " line) 2 1))))
             (cond
              ;; A quote of earlier replies, and the bare ">" that parts
              ;; its paragraphs, is none of the diff.
              ((string-match-p "\\`> ?>" line) (setq ignoring t))
              ((and ignoring (string-empty-p content)))
              (t
               (setq ignoring nil)
               (cond
                ((string-match change-review-mail--patch-marker-regexp content)
                 (setq patch (string-to-number (match-string 1 content))))
                ((string-match-p change-review-mail--elision-regexp (string-trim content))
                 (setq old nil new nil recent nil last nil))
                ((string-prefix-p "diff --git " content)
                 (let ((paths (change-review-mail--header-paths content)))
                   (setq file content
                         path (cdr paths)
                         old-path (and paths (not (equal (car paths) (cdr paths))) (car paths))
                         hunk nil heading "" old nil new nil recent nil
                         last (list 'file))))
                ((and file (string-match change-review-mail--hunk-regexp content))
                 (setq hunk (if hunk (1+ hunk) 0)
                       old (+ (string-to-number (match-string 1 content))
                              (if (equal (match-string 2 content) "0") 1 0))
                       new (+ (string-to-number (match-string 3 content))
                              (if (equal (match-string 4 content) "0") 1 0))
                       heading (match-string 5 content)
                       recent nil
                       last (list 'hunk)))
                ((null file) (prose-line content))
                ((null hunk)
                 (if (string-match-p change-review-mail--diff-header-regexp content)
                     (setq last (list 'file))
                   (prose-line content)))
                (t (content-line content))))))))
      (while lines
        (let* ((raw (pop lines))
               (line (string-trim-right raw)))
          (cond
           ((string-match-p change-review-mail--signature-regexp raw) (setq lines nil))
           ((string-prefix-p ">" line) (quoted line))
           ((string-blank-p line) (setq ignoring nil) (blank))
           ((change-review-mail--attribution-p line) (setq ignoring nil) (finish))
           ((string-match-p change-review-mail--elision-regexp (string-trim line)) (blank))
           (t (setq ignoring nil)
              (unless block (start))
              (push line block-lines)))))
      (finish))
    (nreverse blocks)))

(defun change-review-mail-parse-tip (text)
  "Return the commit that TEXT says its review is of, or nil.
It is the hash in a \"(at HASH)\" of the text, which is how a line before
the first quote can say what the quoted diff is of."
  (when (string-match "(at \\([0-9a-f]\\{7,40\\}\\))" text)
    (match-string 1 text)))

;;;; Importing a reply

(defun change-review-mail--newest-revision (set)
  "Return the revision of SET's newest version, or nil."
  (when-let* ((version (change-review-latest-version set)))
    (change-review-version-id version)))

(defun change-review-mail--tip-version (set tip)
  "Return the version of SET that ends at TIP, a commit or its start, or nil."
  (and tip
       (cl-find-if (lambda (version)
                     (or (and (change-review-version-tip version)
                              (string-prefix-p tip (change-review-version-tip version)))
                         (string-prefix-p tip (change-review-version-id version))))
                   (change-review-set-versions set))))

(defun change-review-mail--patch-of-message (set message-id)
  "Return the index of the patch of SET's versions that mail MESSAGE-ID is, or nil."
  (when message-id
    (cl-some (lambda (version)
               (cl-some (lambda (patch)
                          (and (equal (plist-get patch :message-id) message-id)
                               (plist-get patch :index)))
                        (plist-get (change-review-version-meta version) :patches)))
             (change-review-set-versions set))))

(defun change-review-mail--answered (set message-id)
  "Return (THREAD . COMMENT) for each comment of SET that came in mail MESSAGE-ID.
One for each thread: the mail's last comment in it."
  (let (found)
    (when message-id
      (dolist (thread (change-review-set-threads set))
        (when-let* ((comment (cl-find message-id (change-review-thread-comments thread)
                                      :key (lambda (c) (plist-get (change-review-comment-meta c) :message-id))
                                      :test #'equal :from-end t)))
          (push (cons thread comment) found))))
    (nreverse found)))

(defun change-review-mail--squash (text)
  "Return TEXT with its white space and quote marks as single spaces, trimmed."
  (string-trim (replace-regexp-in-string "[ \t\n>]+" " " text)))

(defun change-review-mail--pick-answered (block candidates)
  "Return the one of CANDIDATES, (THREAD . COMMENT), that BLOCK answers, or nil.
BLOCK is a comment read from a reply (`change-review-mail-parse-reply'),
CANDIDATES the comments of the mail it replies to.  A comment under a
quoted line answers the thread on that line; one that quotes the text of
a comment answers that; one that quotes nothing answers the only
thread there is."
  (let ((path (plist-get block :path))
        (line (plist-get block :line))
        (prose (change-review-mail--squash (string-join (plist-get block :prose) " "))))
    (cond
     ((and path line)
      (cl-find-if (lambda (candidate)
                    (let ((location (change-review-thread-location (car candidate))))
                      (and location
                           (equal (change-review-location-file location) path)
                           (eql (change-review-location-line location) line))))
                  candidates))
     (path nil)
     ((and (not (string-empty-p prose)) (cdr candidates))
      (cl-find-if (lambda (candidate)
                    (let ((body (change-review-mail--squash (change-review-comment-body (cdr candidate)))))
                      (and (not (string-empty-p body))
                           (string-search (substring body 0 (min 40 (length body))) prose))))
                  candidates))
     ((null (cdr candidates)) (car candidates)))))

(cl-defun change-review-mail-import-reply (set text &key author time revision message-id
                                               in-reply-to thread-id-fn split)
  "Add the comments the reply TEXT makes to SET; return them.
TEXT is read with `change-review-mail-parse-reply' (SPLIT is its
argument).  Each comment is added as one of AUTHOR (by default
`change-review-current-author') at TIME (now), already sent, against
REVISION: the version the \"(at HASH)\" of TEXT names, else the newest.
The comment remembers MESSAGE-ID, the mail it came in.

A comment starts a thread of its own, unless it answers one: IN-REPLY-TO
is the id of the mail the reply answers, and when it is that of comments
SET has (they came in that mail) a comment of the reply that is under the
same line, or quotes the text, of one is a reply in its thread; so is a
comment THREAD-ID-FN, a function of the comment's plist, names a thread
of.  What a reply says of a patch of a series, in the quote or by the
mail it answers, goes in the location (`change-review-location-patch').

The ids are made from MESSAGE-ID (else the text), so that adding a reply
again adds nothing."
  (let* ((blocks (change-review-mail-parse-reply text :split split))
         (key (or message-id (secure-hash 'sha1 text)))
         (time (or time (float-time)))
         (author (or author (change-review-current-author set)))
         (revision (or revision
                       (when-let* ((version (change-review-mail--tip-version
                                             set (change-review-mail-parse-tip text))))
                         (change-review-version-id version))
                       (change-review-mail--newest-revision set)))
         (answered (change-review-mail--answered set in-reply-to))
         (reply-patch (change-review-mail--patch-of-message set in-reply-to))
         (index 0)
         (comments nil))
    (dolist (block blocks)
      (let* ((named (and thread-id-fn (funcall thread-id-fn block)))
             (named-thread (and named (change-review-find-thread set named)))
             (parent (cond (named-thread
                            (cons named-thread (change-review-thread-last-comment named-thread)))
                           (named nil)
                           (t (change-review-mail--pick-answered block answered))))
             (comment-id (change-review-stable-id "c" key index))
             (thread-id (cond (parent (change-review-thread-id (car parent)))
                              (named named)
                              (t (change-review-stable-id "t" key index))))
             (path (plist-get block :path))
             (location (and path (not parent)
                            (change-review-make-location
                             :file path :old-file (plist-get block :old-path)
                             :side (plist-get block :side) :line (plist-get block :line)
                             :excerpt (plist-get block :excerpt)
                             :patch (or (plist-get block :patch) reply-patch))))
             (comment (change-review-make-comment
                       :id comment-id :thread thread-id
                       :reply-to (and parent (change-review-comment-id (cdr parent)))
                       :author author :body (plist-get block :body) :time time
                       :location location :revision revision :sent time
                       :meta (change-review--plist :message-id message-id
                                                   :in-reply-to in-reply-to
                                                   :source "mail"))))
        (change-review-dispatch set (list :op 'add-comment :thread thread-id
                                          :comment (change-review-comment-to-data comment)))
        (when-let* ((stored (cdr (change-review-find-comment set comment-id))))
          (push stored comments))
        (cl-incf index)))
    (nreverse comments)))

(defun change-review-mail-import-reply-message (set text)
  "Add the comments the reply mail TEXT makes to SET; return them.
TEXT is a whole mail, as `change-review-mail-parse-message' reads it:
its From is the author, its Date the time, its Message-ID and
In-Reply-To say which mail it is and which it answers
\(`change-review-mail-import-reply').  A mail that holds a patch is no
reply and makes no comment."
  (let ((message (change-review-mail-parse-message text)))
    (unless (change-review-mail--patch-p message)
      (change-review-mail-import-reply
       set (or (plist-get message :body) "")
       :author (change-review-user (or (plist-get message :from-name) (plist-get message :from-email))
                                   (plist-get message :from-email))
       :time (plist-get message :time)
       :message-id (plist-get message :message-id)
       :in-reply-to (plist-get message :in-reply-to)))))

;;;; Writing a reply mail

(defun change-review-mail--address-header (author)
  "Return AUTHOR, a `change-review-author', as an address header has it."
  (let ((name (change-review-author-name author))
        (email (change-review-author-email author)))
    (cond ((and name email)
           (format "%s <%s>" (if (string-match-p "[]\"(),.:;<>@[\\]" name)
                                 (format "\"%s\"" (replace-regexp-in-string "[\"\\]" "\\\\\\&" name))
                               name)
                   email))
          (email email)
          (t (or name "")))))

(defun change-review-mail--re (subject)
  "Return SUBJECT as the subject of a reply to it: one \"Re: \" before it."
  (concat "Re: " (replace-regexp-in-string "\\`\\(?:[Rr][Ee]:[ \t]*\\)+" "" (string-trim (or subject "")))))

(defun change-review-mail--comment-patch (set comment)
  "Return the number of the patch COMMENT of SET is about, or nil."
  (when-let* ((location (change-review-mail--comment-location set comment)))
    (change-review-location-patch location)))

(defun change-review-mail--message-id-p (id)
  "Return non-nil when ID is a message id, \"<...>\"."
  (and (stringp id) (string-match-p "\\`<.*>\\'" id)))

(defun change-review-mail--recipients (value default)
  "Return VALUE, a string or a list of them, as a header's value; else DEFAULT."
  (cond ((stringp value) value)
        ((consp value) (string-join value ", "))
        (t default)))

(cl-defun change-review-mail-reply-message (set &key comments version to cc subject
                                                in-reply-to references from date attribution patch)
  "Return a mail that replies to a version of SET with a review of it.
It is a whole mail, headers and the text of
`change-review-mail-render-comments' (with ATTRIBUTION), ready for
`message-mode', a mail program or `sendmail'.  COMMENTS are those to
write, by default SET's drafts; with PATCH, a number, only those on that
patch of a series, answering the mail of that patch, else the cover
letter.  VERSION is the version replied to (the newest).  The headers
are FROM (an author, by default `change-review-current-author'), TO
\(by default the version's author) and CC (a string or a list of them),
SUBJECT (\"Re: \" and the subject of the mail answered), IN-REPLY-TO and
REFERENCES (message ids; by default the mail answered, and the version's
first), and DATE (a time, by default now)."
  (let* ((version (or (change-review-find-version set version) (change-review-latest-version set)))
         (meta (and version (change-review-version-meta version)))
         (entry (and patch (cl-find patch (plist-get meta :patches)
                                    :key (lambda (p) (plist-get p :index)))))
         (comments (let ((all (or comments (change-review-drafts set))))
                     (if patch
                         (cl-remove-if-not (lambda (c) (eql patch (change-review-mail--comment-patch set c)))
                                           all)
                       all)))
         (first-id (and version (change-review-mail--message-id-p (change-review-version-id version))
                        (change-review-version-id version)))
         (answered (or in-reply-to (plist-get entry :message-id) first-id))
         (author (and version (change-review-version-author version)))
         (headers
          (list (cons "From" (change-review-mail--address-header
                              (or from (change-review-current-author set))))
                (cons "To" (change-review-mail--recipients
                            to (and author (change-review-mail--address-header author))))
                (cons "Cc" (change-review-mail--recipients cc nil))
                (cons "Subject" (change-review-mail--re
                                 (or subject (plist-get entry :subject) (plist-get meta :subject)
                                     (and version (change-review-version-title version))
                                     (change-review-set-title set))))
                (cons "In-Reply-To" answered)
                (cons "References" (string-join
                                    (delete-dups (copy-sequence
                                                  (or references (delq nil (list first-id answered)))))
                                    " "))
                (cons "Date" (let ((system-time-locale "C"))
                               (format-time-string "%a, %d %b %Y %H:%M:%S %z" (or date (current-time)))))
                (cons "MIME-Version" "1.0")
                (cons "Content-Type" "text/plain; charset=utf-8")
                (cons "Content-Transfer-Encoding" "8bit"))))
    (concat (mapconcat (lambda (header) (format "%s: %s" (car header) (cdr header)))
                       (cl-remove-if (lambda (header) (member (cdr header) '(nil "")))
                                     headers)
                       "\n")
            "\n\n"
            (change-review-mail-render-comments set comments :attribution attribution))))

(defun change-review-mail-reply-messages (set &rest keys)
  "Return the reply mails for the review in SET, one for each patch it is about.
Each is (PATCH . TEXT): PATCH the number of the patch of a series, nil
for the comments that are on none, answered at the cover letter; TEXT is
what `change-review-mail-reply-message' gives for it.  KEYS are its
arguments, but for PATCH."
  (let* ((comments (or (plist-get keys :comments) (change-review-drafts set)))
         (patches (delete-dups (mapcar (lambda (c) (change-review-mail--comment-patch set c)) comments))))
    (mapcar (lambda (patch)
              (cons patch
                    (apply #'change-review-mail-reply-message set
                           :comments (cl-remove-if-not
                                      (lambda (c) (eql patch (change-review-mail--comment-patch set c)))
                                      comments)
                           (append (list :patch patch)
                                   (cl-loop for (key value) on keys by #'cddr
                                            unless (memq key '(:comments :patch))
                                            append (list key value))))))
            patches)))

(defun change-review-mail--compose-buffer (set comments text)
  "Open TEXT, a reply mail for COMMENTS of SET, in a `message-mode' buffer.
When the mail is sent the comments are marked sent."
  (require 'message)
  (let ((buffer (generate-new-buffer "*change review reply*"))
        (separator (if (boundp 'mail-header-separator) mail-header-separator "--text follows this line--")))
    (with-current-buffer buffer
      (insert text)
      (goto-char (point-min))
      (when (re-search-forward "^$" nil t)
        (replace-match separator t t))
      (message-mode)
      (let ((ids (mapcar #'change-review-comment-id comments)))
        (add-hook 'message-sent-hook
                  (lambda () (change-review-mark-sent set ids :meta '(:mailed t)))
                  nil t))
      (goto-char (point-min))
      (when (search-forward separator nil t) (forward-line 1)))
    (pop-to-buffer buffer)
    buffer))

(defun change-review-mail-compose (set &rest keys)
  "Open the review in SET as reply mails to send, a buffer for each patch.
KEYS are those of `change-review-mail-reply-messages'.  Return the buffers.
Sending a mail marks the comments in it sent."
  (let ((comments (or (plist-get keys :comments) (change-review-drafts set))))
    (unless comments (user-error "No comments to send"))
    (mapcar (lambda (message)
              (change-review-mail--compose-buffer
               set (cl-remove-if-not (lambda (c) (eql (car message) (change-review-mail--comment-patch set c)))
                                     comments)
               (cdr message)))
            (apply #'change-review-mail-reply-messages set keys))))

(provide 'change-review-mail)
;;; change-review-mail.el ends here
