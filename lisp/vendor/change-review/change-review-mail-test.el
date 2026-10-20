;;; change-review-mail-test.el --- Tests for emailed patches and replies in change-review  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 catvec

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

;; The tests of change-review-mail.el: patch mails and the series they
;; make, the reply format written and read, and replies imported into a
;; set.  The mails are literal texts of the kind `git format-patch' and
;; `git send-email' produce, and a reply as a mailing list reads it.  They
;; need nothing but the library: `make test' runs them in an Emacs with
;; only this directory on its load path.

;;; Code:

(require 'ert)
(require 'bytecomp)
(require 'cl-lib)
(require 'change-review)
(require 'change-review-diff)
(require 'change-review-mail)

(defconst change-review-mail-test--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "The directory of the library and its tests.")

(defun change-review-mail-test--text (&rest lines)
  "Return LINES, strings, as a text: each ends in a newline."
  (mapconcat (lambda (line) (concat line "\n")) lines ""))

;;;; Mails

(defconst change-review-mail-test--patch-1
  (change-review-mail-test--text
   "From 1111111111111111111111111111111111111111 Mon Sep 17 00:00:00 2001"
   "From: Ann Author <ann@example.org>"
   "Date: Mon, 19 Oct 2026 22:36:52 -0400"
   "Subject: [PATCH 1/3] a: shout two and nine"
   "Message-Id: <p1-1@example.org>"
   "In-Reply-To: <cover-1@example.org>"
   "References: <cover-1@example.org>"
   ""
   "Both lines are easier to find when they shout."
   ""
   "Signed-off-by: Ann Author <ann@example.org>"
   "---"
   " a.txt | 4 ++--"
   " 1 file changed, 2 insertions(+), 2 deletions(-)"
   ""
   "diff --git a/a.txt b/a.txt"
   "index c9e9e05..061a3ba 100644"
   "--- a/a.txt"
   "+++ b/a.txt"
   "@@ -1,10 +1,10 @@"
   " one"
   "-two"
   "+TWO"
   " three"
   " four"
   " five"
   " six"
   " seven"
   " eight"
   "-nine"
   "+NINE"
   " ten"
   "-- "
   "2.55.0"
   "")
  "The first patch of a series, as `git send-email' sends it.")

(defconst change-review-mail-test--patch-2
  (change-review-mail-test--text
   "From 2222222222222222222222222222222222222222 Mon Sep 17 00:00:00 2001"
   "From: Ann Author <ann@example.org>"
   "Date: Mon, 19 Oct 2026 22:36:53 -0400"
   "Subject: [PATCH 2/3] b: add gamma"
   "Message-Id: <p2-1@example.org>"
   "In-Reply-To: <cover-1@example.org>"
   "References: <cover-1@example.org>"
   ""
   "---"
   " b.txt | 1 +"
   " 1 file changed, 1 insertion(+)"
   ""
   "diff --git a/b.txt b/b.txt"
   "index fbbee86..85c3040 100644"
   "--- a/b.txt"
   "+++ b/b.txt"
   "@@ -1,2 +1,3 @@"
   " alpha"
   " beta"
   "+gamma"
   "-- "
   "2.55.0"
   "")
  "The second patch: no message but its subject.")

(defconst change-review-mail-test--patch-3
  (change-review-mail-test--text
   "From 3333333333333333333333333333333333333333 Mon Sep 17 00:00:00 2001"
   "From: Ann Author <ann@example.org>"
   "Date: Mon, 19 Oct 2026 22:36:54 -0400"
   "Subject: [PATCH 3/3] c: add a file"
   "Message-Id: <p3-1@example.org>"
   "In-Reply-To: <cover-1@example.org>"
   "References: <cover-1@example.org>"
   ""
   "---"
   " c.txt | 1 +"
   " 1 file changed, 1 insertion(+)"
   " create mode 100644 c.txt"
   ""
   "diff --git a/c.txt b/c.txt"
   "new file mode 100644"
   "index 0000000..fa49b07"
   "--- /dev/null"
   "+++ b/c.txt"
   "@@ -0,0 +1 @@"
   "+new file"
   "\\ No newline at end of file"
   ""
   "base-commit: 0000000000000000000000000000000000000000"
   "-- "
   "2.55.0"
   "")
  "The third patch: a new file with no newline at its end, and a base commit.")

(defconst change-review-mail-test--cover
  (change-review-mail-test--text
   "From 3333333333333333333333333333333333333333 Mon Sep 17 00:00:00 2001"
   "From: Ann Author <ann@example.org>"
   "Date: Mon, 19 Oct 2026 22:36:51 -0400"
   "Subject: [PATCH 0/3] Shout in a.txt and grow b.txt"
   "Message-Id: <cover-1@example.org>"
   ""
   "Three small changes."
   ""
   "Ann Author (3):"
   "  a: shout two and nine"
   "  b: add gamma"
   "  c: add a file"
   ""
   " a.txt | 4 ++--"
   " b.txt | 1 +"
   " c.txt | 1 +"
   " 3 files changed, 4 insertions(+), 2 deletions(-)"
   " create mode 100644 c.txt"
   ""
   "-- "
   "2.55.0"
   "")
  "The cover letter of the series.")

(defconst change-review-mail-test--series
  (concat change-review-mail-test--cover "\n"
          change-review-mail-test--patch-1 "\n"
          change-review-mail-test--patch-2 "\n"
          change-review-mail-test--patch-3)
  "The series as an mbox: the cover letter, then the three patches.")

(defconst change-review-mail-test--v2
  (change-review-mail-test--text
   "From 4444444444444444444444444444444444444444 Mon Sep 17 00:00:00 2001"
   "From: Ann Author <ann@example.org>"
   "Date: Tue, 20 Oct 2026 10:00:00 -0400"
   "Subject: [PATCH v2 0/1] Shout in a.txt"
   "Message-Id: <cover-2@example.org>"
   "In-Reply-To: <cover-1@example.org>"
   "References: <cover-1@example.org>"
   ""
   "Changes since v1: only the first patch is left."
   ""
   "-- "
   "2.55.0"
   ""
   ""
   "From 4444444444444444444444444444444444444444 Mon Sep 17 00:00:00 2001"
   "From: Ann Author <ann@example.org>"
   "Date: Tue, 20 Oct 2026 10:00:01 -0400"
   "Subject: [PATCH v2 1/1] a: shout two and nine"
   "Message-Id: <p1-2@example.org>"
   "In-Reply-To: <cover-1@example.org>"
   "References: <cover-1@example.org>"
   ""
   "Both lines are easier to find when they shout."
   "---"
   " a.txt | 2 +-"
   ""
   "diff --git a/a.txt b/a.txt"
   "index c9e9e05..061a3ba 100644"
   "--- a/a.txt"
   "+++ b/a.txt"
   "@@ -1,3 +1,3 @@"
   " one"
   "-two"
   "+TWO"
   " three"
   "-- "
   "2.55.0"
   "")
  "A v2 that was sent as a reply to the v1's cover letter.")

;;;; Reading mail

(ert-deftest change-review-mail-parses-a-patch-mail ()
  "A patch mail gives its headers, the message that came with the patch
and the patch, without the \"---\", the diffstat and the signature."
  (let ((message (change-review-mail-parse-message change-review-mail-test--patch-1)))
    (should (equal "Ann Author <ann@example.org>" (plist-get message :from)))
    (should (equal "Ann Author" (plist-get message :from-name)))
    (should (equal "ann@example.org" (plist-get message :from-email)))
    (should (equal "[PATCH 1/3] a: shout two and nine" (plist-get message :subject)))
    (should (equal "<p1-1@example.org>" (plist-get message :message-id)))
    (should (equal "<cover-1@example.org>" (plist-get message :in-reply-to)))
    (should (equal '("<cover-1@example.org>") (plist-get message :references)))
    (should (equal "1111111111111111111111111111111111111111" (plist-get message :commit)))
    (should (numberp (plist-get message :time)))
    (should (equal "Mon, 19 Oct 2026 22:36:52 -0400" (plist-get message :date)))
    (should (equal (float-time (encode-time (parse-time-string "Mon, 19 Oct 2026 22:36:52 -0400")))
                   (plist-get message :time)))
    (should (equal "Both lines are easier to find when they shout.\n\nSigned-off-by: Ann Author <ann@example.org>"
                   (plist-get message :body)))
    (let ((patch (plist-get message :patch)))
      (should (string-prefix-p "diff --git a/a.txt b/a.txt\nindex c9e9e05..061a3ba 100644\n" patch))
      (should (string-suffix-p "+NINE\n ten\n" patch))
      (should-not (string-search "2.55.0" patch))
      (should-not (string-search "1 file changed" patch)))
    (should (assoc "message-id" (plist-get message :headers)))
    (should (equal "Mon, 19 Oct 2026 22:36:52 -0400" (cdr (assoc "date" (plist-get message :headers)))))))

(ert-deftest change-review-mail-parses-a-cover-letter-and-a-new-file ()
  "A cover letter has a message and no patch; a patch may end with a base
commit and a missing newline."
  (let ((cover (change-review-mail-parse-message change-review-mail-test--cover))
        (third (change-review-mail-parse-message change-review-mail-test--patch-3)))
    (should-not (plist-get cover :patch))
    (should (string-prefix-p "Three small changes." (plist-get cover :body)))
    (should-not (string-search "2.55.0" (plist-get cover :body)))
    (should (string-search "create mode 100644 c.txt" (plist-get cover :body)))
    (should (equal "0000000000000000000000000000000000000000" (plist-get third :base-commit)))
    (should (string-suffix-p "+new file\n\\ No newline at end of file\n" (plist-get third :patch)))
    (should (equal "" (plist-get third :body)))))

(ert-deftest change-review-mail-tells-a-signature-from-a-deleted-line ()
  "A deleted line that reads \"- \" is the hunk's, not the signature's: the
counts of the hunk say where the diff ends."
  (let* ((text (change-review-mail-test--text
                "From: Ann <ann@example.org>"
                "Subject: [PATCH] list"
                ""
                "---"
                ""
                "diff --git a/l.md b/l.md"
                "--- a/l.md"
                "+++ b/l.md"
                "@@ -1,3 +1,2 @@"
                " item"
                "-- "
                " end"
                "-- "
                "2.55.0"))
         (message (change-review-mail-parse-message text)))
    (should (equal (change-review-mail-test--text
                    "diff --git a/l.md b/l.md" "--- a/l.md" "+++ b/l.md" "@@ -1,3 +1,2 @@"
                    " item" "-- " " end")
                   (plist-get message :patch)))))

(ert-deftest change-review-mail-keeps-a-patch-whose-counts-are-spoiled ()
  "A mail program that spoiled the counts of a hunk does not cut the patch
short: the next hunk or file still belongs to it."
  (let* ((text (change-review-mail-test--text
                "From: Ann <ann@example.org>"
                "Subject: [PATCH] counts"
                ""
                "---"
                ""
                "diff --git a/x b/x"
                "--- a/x"
                "+++ b/x"
                "@@ -1,9 +1,9 @@"
                " a"
                "-b"
                "+B"
                "@@ -20,2 +20,2 @@"
                " y"
                "-z"
                "+Z"
                "diff --git a/y b/y"
                "--- a/y"
                "+++ b/y"
                "@@ -1 +1 @@"
                "-1"
                "+2"
                "-- "
                "2.55.0"))
         (patch (plist-get (change-review-mail-parse-message text) :patch)))
    (should (string-search "@@ -20,2 +20,2 @@" patch))
    (should (string-suffix-p "+2\n" patch))
    (should (equal '("x" "y") (mapcar #'change-review-file-path (change-review-diff-parse patch))))))

(ert-deftest change-review-mail-decodes-what-the-headers-say ()
  "Encoded words, a quoted-printable body, a base64 body and the text parts
of a multipart mail, the patch in a part of its own, all read as text."
  (let ((qp (change-review-mail-parse-message
             (change-review-mail-test--text
              "From: =?UTF-8?Q?Ren=C3=A9_Caf=C3=A9?= <rene@example.org>"
              "Subject: =?UTF-8?q?Re=3A_=5BPATCH=5D_caf=C3=A9?="
              "Content-Type: text/plain; charset=utf-8"
              "Content-Transfer-Encoding: quoted-printable"
              ""
              "Un caf=C3=A9, s'il vous pla=C3=AEt=2E"
              "Une ligne tr=C3=A8s longue qui =
continue ici.")))
        (base64 (change-review-mail-parse-message
                 (change-review-mail-test--text
                  "From: a@example.org"
                  "Subject: encoded"
                  "Content-Type: text/plain; charset=utf-8"
                  "Content-Transfer-Encoding: base64"
                  ""
                  (base64-encode-string (encode-coding-string "Zażółć gęślą jaźń\n" 'utf-8) t))))
        (multipart (change-review-mail-parse-message
                    (change-review-mail-test--text
                     "From: Ann <ann@example.org>"
                     "Subject: [PATCH] attached"
                     "Content-Type: multipart/mixed; boundary=\"XX\""
                     ""
                     "This is a multi-part message."
                     "--XX"
                     "Content-Type: text/plain; charset=utf-8"
                     ""
                     "The message."
                     "---"
                     "--XX"
                     "Content-Type: text/x-patch; name=\"0001.patch\""
                     "Content-Disposition: attachment; filename=\"0001.patch\""
                     ""
                     "diff --git a/x b/x"
                     "--- a/x"
                     "+++ b/x"
                     "@@ -1 +1 @@"
                     "-a"
                     "+b"
                     "--XX"
                     "Content-Type: image/png"
                     ""
                     "not text"
                     "--XX--"))))
    (should (equal "René Café <rene@example.org>" (plist-get qp :from)))
    (should (equal "René Café" (plist-get qp :from-name)))
    (should (equal "Re: [PATCH] café" (plist-get qp :subject)))
    (should (equal "Un café, s'il vous plaît.\nUne ligne très longue qui continue ici." (plist-get qp :body)))
    (should (equal "Zażółć gęślą jaźń" (plist-get base64 :body)))
    (should (equal "The message." (plist-get multipart :body)))
    (should (equal (change-review-mail-test--text "diff --git a/x b/x" "--- a/x" "+++ b/x" "@@ -1 +1 @@" "-a" "+b")
                   (plist-get multipart :patch)))
    (should-not (string-search "not text" (or (plist-get multipart :patch) "")))))

(ert-deftest change-review-mail-reads-bytes-and-carriage-returns ()
  "A mail given as bytes is read as UTF-8, one with CR LF line ends as one
with LF."
  (let ((crlf (replace-regexp-in-string "\n" "\r\n" change-review-mail-test--patch-1))
        (bytes (encode-coding-string
                (change-review-mail-test--text "From: Zoë <z@example.org>" "Subject: café" "" "Tëxt.")
                'utf-8)))
    (should (equal (change-review-mail-parse-message change-review-mail-test--patch-1)
                   (change-review-mail-parse-message crlf)))
    (should-not (multibyte-string-p bytes))
    (let ((message (change-review-mail-parse-message bytes)))
      (should (equal "Zoë" (plist-get message :from-name)))
      (should (equal "café" (plist-get message :subject)))
      (should (equal "Tëxt." (plist-get message :body))))))

(ert-deftest change-review-mail-reads-the-charset-of-a-mail-given-as-bytes ()
  "A mail file read as bytes is read in the charset its headers name, each
mail of an mbox in its own."
  (let* ((latin (concat (change-review-mail-test--text
                         "From MAILER-DAEMON Mon Oct 19 22:36:52 2026"
                         "From: =?ISO-8859-1?Q?Ren=E9?= <r@example.org>"
                         "Subject: caf\351"
                         "Content-Type: text/plain; charset=iso-8859-1"
                         "Content-Transfer-Encoding: 8bit"
                         "")
                        "Un caf" (unibyte-string 233) "\n\n"))
         (utf (encode-coding-string
               (change-review-mail-test--text
                "From MAILER-DAEMON Tue Oct 20 10:00:00 2026"
                "From: Zoë <z@example.org>"
                "Subject: café"
                "Content-Type: text/plain; charset=utf-8"
                ""
                "Un café.")
               'utf-8))
         (bytes (concat (encode-coding-string "" 'utf-8) (string-to-unibyte (concat latin utf))))
         (messages (change-review-mail-parse-mbox bytes)))
    (should-not (multibyte-string-p bytes))
    (should (equal '("René" "Zoë") (mapcar (lambda (m) (plist-get m :from-name)) messages)))
    (should (equal '("Un café" "Un café.") (mapcar (lambda (m) (plist-get m :body)) messages)))
    (should (equal "café" (plist-get (car messages) :subject)))))

(ert-deftest change-review-mail-reads-a-text-with-no-headers ()
  "A text with no headers is a message with none; a bare diff is its patch."
  (let ((diff (change-review-mail-test--text "diff --git a/x b/x" "--- a/x" "+++ b/x" "@@ -1 +1 @@" "-a" "+b"))
        (note (change-review-mail-parse-message "Just words.\n\nMore words.\n")))
    (let ((message (change-review-mail-parse-message diff)))
      (should-not (plist-get message :headers))
      (should-not (plist-get message :subject))
      (should (equal diff (plist-get message :patch)))
      (should (equal "" (plist-get message :body))))
    (should (equal "Just words.\n\nMore words." (plist-get note :body)))
    (should-not (plist-get note :patch))
    ;; A plain diff, with no "diff --git" line.
    (should (equal (change-review-mail-test--text "--- a/x" "+++ b/x" "@@ -1 +1 @@" "-a" "+b")
                   (plist-get (change-review-mail-parse-message
                               (change-review-mail-test--text "Fix it." "" "--- a/x" "+++ b/x" "@@ -1 +1 @@" "-a" "+b"))
                              :patch)))))

(ert-deftest change-review-mail-reads-an-mbox ()
  "An mbox is split at its mbox lines, \">From \" unquoted; several files of
format-patch put together are one; a mail with no mbox line is one."
  (let ((messages (change-review-mail-parse-mbox change-review-mail-test--series)))
    (should (equal '("[PATCH 0/3] Shout in a.txt and grow b.txt" "[PATCH 1/3] a: shout two and nine"
                     "[PATCH 2/3] b: add gamma" "[PATCH 3/3] c: add a file")
                   (mapcar (lambda (m) (plist-get m :subject)) messages)))
    (should (equal '(nil t t t) (mapcar (lambda (m) (and (plist-get m :patch) t)) messages))))
  (let* ((mbox (change-review-mail-test--text
                "From MAILER-DAEMON Mon Oct 19 22:36:52 2026"
                "From: a@example.org"
                "Subject: one"
                ""
                ">From the start"
                ">>From twice"
                ""
                "From b@example.org Tue Oct 20 10:00:00 2026"
                "From: b@example.org"
                "Subject: two"
                ""
                "Second."))
         (messages (change-review-mail-parse-mbox mbox)))
    (should (equal '("one" "two") (mapcar (lambda (m) (plist-get m :subject)) messages)))
    (should (equal "From the start\n>From twice" (plist-get (car messages) :body)))
    (should (equal "Second." (plist-get (cadr messages) :body))))
  (should (= 1 (length (change-review-mail-parse-mbox change-review-mail-test--patch-2))))
  (should (equal "[PATCH 2/3] b: add gamma"
                 (plist-get (car (change-review-mail-parse-mbox
                                  (substring change-review-mail-test--patch-2
                                             (1+ (string-search "\n" change-review-mail-test--patch-2)))))
                            :subject))))

(ert-deftest change-review-mail-parses-subjects ()
  "The tag of a subject gives the kind, the version, the place in the series
and the title."
  (pcase-dolist (`(,subject . ,expected)
                 '(("[PATCH v2 1/3] a: b" . (:tags ("PATCH" "v2") :kind "PATCH" :rfc nil :version 2
                                                   :index 1 :count 3 :reply nil :title "a: b"))
                   ("Re: [RFC PATCH v3 net-next 0/5] x y"
                    . (:tags ("RFC" "PATCH" "v3" "net-next") :kind "PATCH" :rfc t :version 3
                             :index 0 :count 5 :reply t :title "x y"))
                   ("[PATCH] one" . (:tags ("PATCH") :kind "PATCH" :rfc nil :version 1
                                           :index nil :count nil :reply nil :title "one"))
                   ("[RFC] idea" . (:tags ("RFC") :kind "RFC" :rfc t :version 1
                                          :index nil :count nil :reply nil :title "idea"))
                   ("plain words" . (:tags nil :kind nil :rfc nil :version 1
                                           :index nil :count nil :reply nil :title "plain words"))
                   ("Re: Re: [PATCH 2/2] z" . (:tags ("PATCH") :kind "PATCH" :rfc nil :version 1
                                                     :index 2 :count 2 :reply t :title "z"))
                   ("[PATCH][V4] q" . (:tags ("PATCH" "V4") :kind "PATCH" :rfc nil :version 4
                                             :index nil :count nil :reply nil :title "q"))
                   ("[PATCH v10 12/30] long" . (:tags ("PATCH" "v10") :kind "PATCH" :rfc nil :version 10
                                                     :index 12 :count 30 :reply nil :title "long"))
                   ("" . (:tags nil :kind nil :rfc nil :version 1 :index nil :count nil :reply nil :title ""))))
    (ert-info ((format "%S" subject))
      (should (equal expected (change-review-mail-parse-subject subject)))))
  (should (equal "" (plist-get (change-review-mail-parse-subject nil) :title))))

;;;; Series and versions

(defconst change-review-mail-test--reply-mail
  (change-review-mail-test--text
   "From: Bob Reviewer <bob@example.org>"
   "Date: Tue, 20 Oct 2026 09:15:02 +0000"
   "Subject: Re: [PATCH 1/3] a: shout two and nine"
   "Message-ID: <r1@example.org>"
   "In-Reply-To: <p1-1@example.org>"
   "References: <cover-1@example.org> <p1-1@example.org>"
   ""
   "On Mon, Oct 19, 2026 at 10:36 PM Ann Author <ann@example.org> wrote:"
   "> > Please send it as a series."
   ">"
   "> Both lines are easier to find when they shout."
   "> ---"
   ">  a.txt | 4 ++--"
   ">"
   "> diff --git a/a.txt b/a.txt"
   "> index c9e9e05..061a3ba 100644"
   "> --- a/a.txt"
   "> +++ b/a.txt"
   "> @@ -1,10 +1,10 @@"
   ">  one"
   "> -two"
   "> +TWO"
   ">  three"
   "> [...]"
   "> @@ -8,3 +8,3 @@"
   ">  eight"
   "> -nine"
   "> +NINE"
   ">  ten"
   ""
   "Why shout \"nine\"? It reads like a constant."
   ""
   "Looks good otherwise."
   ""
   "Thanks,"
   "Bob"
   "-- "
   "Bob Reviewer"
   "")
  "A reply to the first patch, as a mailing list reads one.")

(ert-deftest change-review-mail-groups-mails-into-series ()
  "Mails make a series by their version and thread: a v2 that answers the
v1's cover letter is another series; replies and strangers belong to none."
  (let* ((text (concat change-review-mail-test--series "\n" change-review-mail-test--v2 "\n"
                       change-review-mail-test--reply-mail "\n"
                       (change-review-mail-test--text "From: x@example.org" "Subject: lunch?" "" "Noon?")))
         (messages (change-review-mail-parse-mbox text))
         (series (change-review-mail-series messages)))
    (should (= 6 (length messages)))
    (should (= 2 (length series)))
    (let ((v1 (nth 0 series)) (v2 (nth 1 series)))
      (should (equal '(1 2) (mapcar (lambda (s) (plist-get s :version)) series)))
      (should (equal "Shout in a.txt and grow b.txt" (plist-get v1 :title)))
      (should (equal "<cover-1@example.org>" (plist-get v1 :message-id)))
      (should (equal "[PATCH 0/3] Shout in a.txt and grow b.txt" (plist-get (plist-get v1 :cover) :subject)))
      (should (equal '("<p1-1@example.org>" "<p2-1@example.org>" "<p3-1@example.org>")
                     (mapcar (lambda (m) (plist-get m :message-id)) (plist-get v1 :patches))))
      (should (equal "Ann Author" (change-review-author-name (plist-get v1 :author))))
      (should (equal "ann@example.org" (change-review-author-email (plist-get v1 :author))))
      (should (numberp (plist-get v1 :time)))
      (should (equal "<cover-2@example.org>" (plist-get v2 :message-id)))
      (should (= 1 (length (plist-get v2 :patches))))
      (should (> (plist-get v2 :time) (plist-get v1 :time))))))

(ert-deftest change-review-mail-groups-a-series-sent-without-threads ()
  "Numbered patches sent without threading headers, each the start of a
thread of its own, are one series by their sender and version; a single
patch is a series by itself."
  (let* ((strip (lambda (text) (replace-regexp-in-string "^\\(In-Reply-To\\|References\\):.*\n" "" text)))
         (text (funcall strip (concat change-review-mail-test--cover "\n" change-review-mail-test--patch-1 "\n"
                                      change-review-mail-test--patch-2 "\n" change-review-mail-test--patch-3 "\n"
                                      (change-review-mail-test--text
                                       "From 5555555555555555555555555555555555555555 Mon Sep 17 00:00:00 2001"
                                       "From: Ann Author <ann@example.org>"
                                       "Subject: [PATCH] d: a separate fix"
                                       "Message-Id: <p4@example.org>"
                                       ""
                                       "---"
                                       "diff --git a/d.txt b/d.txt"
                                       "--- a/d.txt"
                                       "+++ b/d.txt"
                                       "@@ -1 +1 @@"
                                       "-x"
                                       "+y"))))
         (series (change-review-mail-series (change-review-mail-parse-mbox text))))
    (should (= 2 (length series)))
    (should (equal '(4 1) (sort (mapcar (lambda (s) (+ (length (plist-get s :patches))
                                                       (if (plist-get s :cover) 1 0)))
                                        series)
                                #'>)))
    (should (cl-find-if (lambda (s) (plist-get s :cover)) series))
    (should (equal '("d: a separate fix")
                   (mapcar (lambda (s) (plist-get s :title))
                           (cl-remove-if (lambda (s) (plist-get s :cover)) series))))))

(ert-deftest change-review-mail-puts-patches-in-order ()
  "The patches of a series are in the order of their index, whatever the
order the mails came in."
  (let* ((text (concat change-review-mail-test--patch-3 "\n" change-review-mail-test--patch-1 "\n"
                       change-review-mail-test--patch-2 "\n" change-review-mail-test--cover))
         (series (change-review-mail-series (change-review-mail-parse-mbox text))))
    (should (= 1 (length series)))
    (should (equal '("a: shout two and nine" "b: add gamma" "c: add a file")
                   (mapcar (lambda (m) (plist-get (change-review-mail-parse-subject (plist-get m :subject)) :title))
                           (plist-get (car series) :patches))))))

(ert-deftest change-review-mail-tells-series-apart-without-ids ()
  "Mails with no message ids still make a series of each version, and an
index met a second time starts another series of the same version."
  (let* ((strip (lambda (text) (replace-regexp-in-string "^\\(Message-Id\\|In-Reply-To\\|References\\):.*\n" "" text)))
         (one (funcall strip (concat change-review-mail-test--patch-1 "\n" change-review-mail-test--patch-2)))
         (again (funcall strip (concat change-review-mail-test--patch-1 "\n"))))
    (let ((series (change-review-mail-series (change-review-mail-parse-mbox (concat one "\n" again)))))
      (should (= 2 (length series)))
      (should (equal '(2 1) (mapcar (lambda (s) (length (plist-get s :patches))) series))))
    (let ((series (change-review-mail-series
                   (change-review-mail-parse-mbox
                    (funcall strip (concat change-review-mail-test--patch-1 "\n" change-review-mail-test--v2))))))
      (should (equal '(1 2) (mapcar (lambda (s) (plist-get s :version)) series))))))

(ert-deftest change-review-mail-makes-a-version-of-a-series ()
  "A series is a version: named by the cover letter's id, with the files of
every patch, each marked with its patch, and the description of the cover."
  (let* ((series (car (change-review-mail-series (change-review-mail-parse-mbox change-review-mail-test--series))))
         (version (change-review-mail-version series)))
    (should (equal "<cover-1@example.org>" (change-review-version-id version)))
    (should (equal "v1" (change-review-version-label version)))
    (should-not (change-review-version-number version))
    (should (equal "Shout in a.txt and grow b.txt" (change-review-version-title version)))
    (should (string-prefix-p "Three small changes." (change-review-version-description version)))
    (should (equal "Ann Author" (change-review-author-name (change-review-version-author version))))
    (should (numberp (change-review-version-time version)))
    (should (equal "3333333333333333333333333333333333333333" (change-review-version-tip version)))
    (should (equal "0000000000000000000000000000000000000000" (change-review-version-base version)))
    (should (equal '(("a.txt" . 1) ("b.txt" . 2) ("c.txt" . 3))
                   (mapcar (lambda (f) (cons (change-review-file-path f) (change-review-file-patch-id f)))
                           (change-review-version-files version))))
    (let ((meta (change-review-version-meta version)))
      (should (plist-get meta :series))
      (should (equal "[PATCH 0/3] Shout in a.txt and grow b.txt" (plist-get meta :subject)))
      (should (equal '(1 2 3) (mapcar (lambda (p) (plist-get p :index)) (plist-get meta :patches))))
      (should (equal '("a: shout two and nine" "b: add gamma" "c: add a file")
                     (mapcar (lambda (p) (plist-get p :title)) (plist-get meta :patches))))
      (should (equal '("<p1-1@example.org>" "<p2-1@example.org>" "<p3-1@example.org>")
                     (mapcar (lambda (p) (plist-get p :message-id)) (plist-get meta :patches))))
      (should (equal "1111111111111111111111111111111111111111"
                     (plist-get (car (plist-get meta :patches)) :commit)))
      (should (string-prefix-p "Both lines" (plist-get (car (plist-get meta :patches)) :body))))
    ;; The meta, like the rest, is plain data.
    (should (equal (change-review-version-to-data version t)
                   (change-review-version-to-data
                    (change-review-version-from-data (change-review-version-to-data version t)) t)))))

(ert-deftest change-review-mail-a-single-patch-has-no-patch-ids ()
  "A series of one patch marks no file with a patch, and without a cover
letter its first patch names the version."
  (let* ((series (car (change-review-mail-series (change-review-mail-parse-mbox change-review-mail-test--patch-2))))
         (version (change-review-mail-version series)))
    (should (equal "<p2-1@example.org>" (change-review-version-id version)))
    (should (equal "b: add gamma" (change-review-version-title version)))
    (should-not (change-review-version-description version))
    (should (equal '(nil) (mapcar #'change-review-file-patch-id (change-review-version-files version))))
    (should (equal '("b.txt") (mapcar #'change-review-file-path (change-review-version-files version))))))

(ert-deftest change-review-mail-imports-patches ()
  "Importing a text adds a version for each series, oldest first, to a set
it makes when it is given none; importing it again adds nothing."
  (let* ((text (concat change-review-mail-test--v2 "\n" change-review-mail-test--series))
         (versions (change-review-mail-import-patches nil text)))
    (should (= 2 (length versions)))
    (should (equal '("v1" "v2") (mapcar #'change-review-version-label versions)))
    (let ((set (change-review-make-set :id "mine")))
      (let ((first (change-review-mail-import-patches set text)))
        (should (equal '(1 2) (mapcar #'change-review-version-number first)))
        (should (eq (car first) (change-review-find-version set "<cover-1@example.org>"))))
      (let ((again (change-review-mail-import-patches set text)))
        (should (= 2 (length (change-review-set-versions set))))
        (should (equal '(1 2) (mapcar #'change-review-version-number again)))
        (should (equal '("a.txt" "b.txt" "c.txt")
                       (mapcar #'change-review-file-path
                               (change-review-version-files (car again)))))))
    ;; A set it makes has the title of the first series.
    (let ((versions (change-review-mail-import-patches nil change-review-mail-test--series)))
      (should (equal "Shout in a.txt and grow b.txt" (change-review-version-title (car versions)))))
    (should-error (change-review-mail-import-patches nil "Nothing to see here.\n")
                  :type 'change-review-error)))

(ert-deftest change-review-mail-makes-a-set-of-patches ()
  "A set is made of the patches in a text or a file, titled by the first
series; the file is read as bytes."
  (let ((set (change-review-mail-make-set change-review-mail-test--series)))
    (should (change-review-set-p set))
    (should (equal "Shout in a.txt and grow b.txt" (change-review-set-title set)))
    (should (equal '("v1") (mapcar #'change-review-version-label (change-review-set-versions set)))))
  (let ((file (make-temp-file "change-review-mail" nil ".mbox")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region (replace-regexp-in-string "Shout in" "Crie é" change-review-mail-test--series)
                          nil file nil 'silent))
          (let ((set (change-review-mail-make-set-from-file file)))
            (should (equal "Crie é a.txt and grow b.txt" (change-review-set-title set)))
            (should (= 3 (length (change-review-version-files (car (change-review-set-versions set))))))))
      (delete-file file)))
  (should-error (change-review-mail-make-set "nothing") :type 'change-review-error))

(ert-deftest change-review-mail-imports-a-bare-diff ()
  "A unified diff with no mail around it is a version titled by its first
file; the same text again is the same version."
  (let* ((diff (change-review-mail-test--text
                "diff --git a/src/x.el b/src/x.el"
                "index 1..2 100644"
                "--- a/src/x.el"
                "+++ b/src/x.el"
                "@@ -1,2 +1,2 @@"
                " (a)"
                "-(b)"
                "+(c)"
                "diff --git a/y.el b/y.el"
                "--- a/y.el"
                "+++ b/y.el"
                "@@ -1 +1 @@"
                "-1"
                "+2"))
         (set (change-review-make-set)))
    (let ((versions (change-review-mail-import-patches set diff)))
      (should (= 1 (length versions)))
      (should (equal "src/x.el" (change-review-version-title (car versions))))
      (should (equal '("src/x.el" "y.el") (mapcar #'change-review-file-path
                                                  (change-review-version-files (car versions)))))
      (should (equal '(nil nil) (mapcar #'change-review-file-patch-id (change-review-version-files (car versions)))))
      (should (string-prefix-p "v-" (change-review-version-id (car versions)))))
    (change-review-mail-import-patches set diff)
    (should (= 1 (length (change-review-set-versions set))))
    (should (= 1 (length (change-review-set-versions
                          (let ((other (change-review-make-set)))
                            (change-review-mail-import-patches other diff)
                            (change-review-mail-import-patches other (concat diff "\n"))
                            other)))))))

;;;; Writing a reply

(defun change-review-mail-test--set ()
  "Return a set with one version whose files are a.el, b.el, d.el and new.el."
  (let ((set (change-review-make-set :id "s" :title "Fix it")))
    (change-review-add-version
     set (change-review-make-version
          :id "tip" :files (mapcar (lambda (p) (change-review-make-file :path p))
                                   '("a.el" "b.el" "d.el" "new.el"))))
    set))

(defun change-review-mail-test--add (set file side line body excerpt &rest keys)
  "Add a draft comment BODY to SET on FILE at LINE of SIDE, quoting EXCERPT.
KEYS are `change-review-comment' keys; :old-file names the file before a
rename."
  (let ((old-file (plist-get keys :old-file))
        (rest (cl-loop for (key value) on keys by #'cddr
                       unless (eq key :old-file) append (list key value))))
    (apply #'change-review-comment set body
           (append rest
                   (list :author (change-review-user "Alice") :revision "tip"
                         :location (change-review-make-location :file file :old-file old-file :side side
                                                                :line line :excerpt excerpt))))))

(defconst change-review-mail-test--a18
  "@@ -15,4 +15,4 @@\n (setq a15 15)\n (setq a16 16)\n (setq a17 17)\n-(setq a18 18)\n+(setq a18 'eighteen)"
  "The excerpt of a comment on line 18 of a.el.")

(defconst change-review-mail-test--attribution
  "My comments on the diff of your branch task/fix (at 0123456) against main (merge base 7654321), each under the lines it is about:"
  "The line that says what the quote of a review is.")

(defun change-review-mail-test--review ()
  "Return a set with the comments of a review, and the text they make."
  (let ((set (change-review-mail-test--set)))
    (change-review-mail-test--add set "a.el" 'new 18 "Why eighteen?" change-review-mail-test--a18)
    (change-review-mail-test--add set "a.el" 'new 18 "And the tests?" change-review-mail-test--a18)
    (change-review-mail-test--add set "a.el" 'new 12 "Too far" "@@ -15,1 +15,1 @@\n (setq a15 15)")
    (change-review-mail-test--add set "b.el" 'old 3 "Who used b3?"
                                  "@@ -1,3 +0,0 @@\n-(setq b1 1)\n-(setq b2 2)\n-(setq b3 3)")
    (change-review-mail-test--add set "new.el" nil nil "Needs a test" nil)
    (change-review-mail-test--add set "a.el" 'new 2 "Why two?"
                                  "@@ -1,2 +1,2 @@\n (setq a1 1)\n-(setq a2 2)\n+(setq a2 'two)")
    (change-review-mail-test--add set "a.el" 'new 20 "And twenty?"
                                  "@@ -18,3 +18,3 @@\n-(setq a18 18)\n+(setq a18 'eighteen)\n (setq a19 19)\n (setq a20 20)")
    (change-review-mail-test--add set "d.el" 'new 6 "Six?"
                                  "@@ -3,4 +3,4 @@\n (setq c3 3)\n (setq c4 4)\n (setq c5 5)\n-(setq c6 6)\n+(setq c6 'six)"
                                  :old-file "c.el")
    (change-review-mail-test--add set "a.el" nil nil "Split this up" nil)
    set))

(defconst change-review-mail-test--review-text
  (concat change-review-mail-test--attribution "\n"
          "\n"
          "> diff --git a/a.el b/a.el\n"
          "\n"
          "Split this up\n"
          "\n"
          "> @@ -1,2 +1,2 @@\n"
          ">  (setq a1 1)\n"
          "> -(setq a2 2)\n"
          "> +(setq a2 'two)\n"
          "\n"
          "Why two?\n"
          "\n"
          "> @@ -15,6 +15,6 @@\n"
          ">  (setq a15 15)\n"
          "\n"
          "On line 12: Too far\n"
          "\n"
          ">  (setq a16 16)\n"
          ">  (setq a17 17)\n"
          "> -(setq a18 18)\n"
          "> +(setq a18 'eighteen)\n"
          "\n"
          "Why eighteen?\n"
          "\n"
          "And the tests?\n"
          "\n"
          ">  (setq a19 19)\n"
          ">  (setq a20 20)\n"
          "\n"
          "And twenty?\n"
          "\n"
          "> diff --git a/b.el b/b.el\n"
          "> @@ -1,3 +0,0 @@\n"
          "> -(setq b1 1)\n"
          "> -(setq b2 2)\n"
          "> -(setq b3 3)\n"
          "\n"
          "Who used b3?\n"
          "\n"
          "> diff --git a/c.el b/d.el\n"
          "> @@ -3,4 +3,4 @@\n"
          ">  (setq c3 3)\n"
          ">  (setq c4 4)\n"
          ">  (setq c5 5)\n"
          "> -(setq c6 6)\n"
          "> +(setq c6 'six)\n"
          "\n"
          "Six?\n"
          "\n"
          "> diff --git a/new.el b/new.el\n"
          "\n"
          "Needs a test\n")
  "What the comments of `change-review-mail-test--review' make.")

(ert-deftest change-review-mail-writes-comments-under-their-lines ()
  "Comments go under the lines they are about, quoted from the diff once:
the files in the order of the version, a file's comments in the order of
its lines, the quote going on after a comment, a line the diff does not
have named in the comment, a comment on a file as a whole under its first
line.  The hunk header counts all the lines of its quote."
  (let ((set (change-review-mail-test--review)))
    (should (equal change-review-mail-test--review-text
                   (change-review-mail-render-comments
                    set (change-review-drafts set)
                    :attribution change-review-mail-test--attribution)))))

(ert-deftest change-review-mail-writes-what-has-no-quote-first ()
  "A comment on the change as a whole comes first, before the attribution;
no quote, no attribution; no comment, no text."
  (let ((set (change-review-mail-test--set)))
    (should (equal "" (change-review-mail-render-comments set nil :attribution "Attributed:")))
    (let ((general (change-review-comment set "Nearly there." :author (change-review-user "A")))
          (b (change-review-mail-test--add set "b.el" 'old 5 "Who used these?"
                                           "@@ -1,5 +0,0 @@\n-(setq b1 1)\n-(setq b2 2)\n-(setq b3 3)\n-(setq b4 4)\n-(setq b5 5)")))
      (should (equal "Nearly there.\n" (change-review-mail-render-comments set (list general) :attribution "Attributed:")))
      (should (equal (concat "Nearly there.\n\nAttributed:\n\n"
                             "> diff --git a/b.el b/b.el\n"
                             "> @@ -1,5 +0,0 @@\n"
                             "> -(setq b1 1)\n> -(setq b2 2)\n> -(setq b3 3)\n> -(setq b4 4)\n> -(setq b5 5)\n"
                             "\n"
                             "Who used these?\n")
                     (change-review-mail-render-comments set (list b general) :attribution "Attributed:")))
      (should (equal (concat "> diff --git a/b.el b/b.el\n> @@ -1,5 +0,0 @@\n"
                             "> -(setq b1 1)\n> -(setq b2 2)\n> -(setq b3 3)\n> -(setq b4 4)\n> -(setq b5 5)\n"
                             "\nWho used these?\n")
                     (change-review-mail-render-comments set (list b)))))))

(ert-deftest change-review-mail-names-the-line-of-the-old-file ()
  "A comment on a line of the old file that the quote ends before says so."
  (let* ((set (change-review-mail-test--set))
         (comment (change-review-mail-test--add set "a.el" 'old 30 "Past the end"
                                                "@@ -19,2 +19,2 @@\n (setq a19 19)\n (setq a20 20)")))
    (should (equal (concat "> diff --git a/a.el b/a.el\n> @@ -19,2 +19,2 @@\n>  (setq a19 19)\n>  (setq a20 20)\n"
                           "\nOn line 30 of the merge base: Past the end\n")
                   (change-review-mail-render-comments set (list comment))))))

(ert-deftest change-review-mail-keeps-a-missing-newline-marker-with-its-line ()
  "The line that marks a missing newline stays right after the line it is
about, and the comment goes after it."
  (let* ((set (change-review-mail-test--set))
         (comment (change-review-mail-test--add
                   set "a.el" 'new 3 "No newline?"
                   "@@ -2,2 +2,2 @@\n (setq a2 2)\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file"))
         (other (change-review-mail-test--add set "a.el" 'new 3 "Hm."
                                              "@@ -2,2 +2,2 @@\n (setq a2 2)\n-old\n\\ No newline at end of file\n+new")))
    (should (equal (concat "> diff --git a/a.el b/a.el\n> @@ -2,4 +2,2 @@\n"
                           ">  (setq a2 2)\n> -old\n> \\ No newline at end of file\n> +new\n"
                           "> \\ No newline at end of file\n\nNo newline?\n\nHm.\n")
                   (let ((text (change-review-mail-render-comments set (list comment other))))
                     ;; Counting only the lines of the diff, not the markers.
                     (replace-regexp-in-string "@@ -2,[0-9]+ \\+2,[0-9]+ @@" "@@ -2,4 +2,2 @@" text))))
    (let ((text (change-review-mail-render-comments set (list comment))))
      (should (string-match-p "\\\\ No newline at end of file\n\nNo newline\\?\n\\'" text))
      (should (= 2 (cl-count ?\\ text))))))

(ert-deftest change-review-mail-fills-only-what-needs-it ()
  "A paragraph with a line wider than the fill column is filled; a short one
and a block of code are not; no line of a comment starts with \">\"."
  (let* ((set (change-review-mail-test--set))
         (long (string-join (make-list 40 "word") " "))
         (comment (change-review-mail-test--add
                   set "a.el" 'new 1 (concat long "\n\nshort\nlines stay\n\n    (code (stays))\n    (code (too))\n\n> not a quote")
                   "@@ -1,1 +1,1 @@\n (setq a1 1)"))
         (text (change-review-mail-render-comments set (list comment)))
         (body (substring text (+ 2 (string-search "\n\n" text)))))
    (should (cl-every (lambda (line) (<= (length line) change-review-mail-fill-column))
                      (split-string body "\n")))
    (should (string-search "\n\nshort\nlines stay\n\n    (code (stays))\n    (code (too))\n\n >" (concat "\n" body)))
    (should (string-search " > not a quote" body))
    (should-not (string-match-p "^>" (substring body 1)))
    (let ((change-review-mail-fill-column 20))
      (should (cl-every (lambda (line) (<= (length line) 20))
                        (split-string
                         (let ((text (change-review-mail-render-comments
                                      set (list (change-review-mail-test--add
                                                 set "a.el" 'new 1 long "@@ -1,1 +1,1 @@\n (setq a1 1)")))))
                           (substring text (+ 2 (string-search "\n\n" text))))
                         "\n"))))))

(ert-deftest change-review-mail-writes-a-comment-whose-excerpt-is-broken ()
  "A comment whose excerpt has no hunk header cannot be put under its lines:
it is written on its file, saying the line."
  (let* ((set (change-review-mail-test--set))
         (comment (change-review-mail-test--add set "a.el" 'new 7 "Hm." " (setq a7 7)\n+(setq a8 8)")))
    (should (equal "> diff --git a/a.el b/a.el\n\nOn line 7: Hm.\n"
                   (change-review-mail-render-comments set (list comment))))))

(ert-deftest change-review-mail-writes-markers-and-history ()
  "A marker line goes right after a comment; the earlier messages of a thread
come before its first comment in the reply, once."
  (let* ((set (change-review-mail-test--set))
         (root (change-review-mail-test--add set "a.el" 'new 18 "Why eighteen?" change-review-mail-test--a18
                                             :sent 1 :time 1))
         (answer (change-review-reply set root "Because\nthe retry loop." :author (change-review-agent "Claude")
                                      :time 2 :sent 2))
         (again (change-review-reply set answer "Then say so." :author (change-review-user "Alice") :time 3))
         (more (change-review-reply set answer "And add a test." :author (change-review-user "Alice") :time 4))
         (marker (lambda (c) (format "[%s]" (change-review-thread-id
                                             (car (change-review-find-comment set (change-review-comment-id c))))))))
    (let ((text (change-review-mail-render-comments set (list again more) :history t :markers marker)))
      (should (equal (concat "> diff --git a/a.el b/a.el\n"
                             "> @@ -15,4 +15,4 @@\n"
                             ">  (setq a15 15)\n>  (setq a16 16)\n>  (setq a17 17)\n"
                             "> -(setq a18 18)\n> +(setq a18 'eighteen)\n"
                             "\n"
                             "Earlier in this thread:\n"
                             "  Alice: Why eighteen?\n"
                             "  Claude: Because\n"
                             "    the retry loop.\n"
                             "\n"
                             "Then say so.\n"
                             (format "[%s]\n" (change-review-comment-thread root))
                             "\n"
                             "And add a test.\n"
                             (format "[%s]\n" (change-review-comment-thread root)))
                     text)))
    ;; The location is the thread's: a reply has none of its own.
    (should-not (change-review-comment-location again))
    (should-not (string-search "Earlier in this thread"
                               (change-review-mail-render-comments set (list again))))))

(ert-deftest change-review-mail-names-the-patch-of-a-series ()
  "Comments on several patches of a series are written with a line that says
which patch each quote is of."
  (let* ((versions (change-review-mail-import-patches nil change-review-mail-test--series))
         (set (change-review-make-set))
         (_ (change-review-add-version set (car versions)))
         (one (change-review-comment
               set "Shouting?" :author (change-review-user "Bob") :time 1
               :location (change-review-make-location :file "a.txt" :line 2 :patch 1
                                                      :excerpt "@@ -1,2 +1,2 @@\n one\n-two\n+TWO")))
         (three (change-review-comment
                 set "Why a file?" :author (change-review-user "Bob") :time 2
                 :location (change-review-make-location :file "c.txt" :line 1 :patch 3
                                                        :excerpt "@@ -0,0 +1,1 @@\n+new file"))))
    (should (equal (concat "> [PATCH 1/3] a: shout two and nine\n"
                           "> diff --git a/a.txt b/a.txt\n"
                           "> @@ -1,2 +1,2 @@\n>  one\n> -two\n> +TWO\n"
                           "\nShouting?\n\n"
                           "> [PATCH 3/3] c: add a file\n"
                           "> diff --git a/c.txt b/c.txt\n"
                           "> @@ -0,0 +1,1 @@\n> +new file\n"
                           "\nWhy a file?\n")
                   (change-review-mail-render-comments set (list three one))))
    ;; With one patch only, no line.
    (should-not (string-search "[PATCH" (change-review-mail-render-comments set (list one))))))

(ert-deftest change-review-mail-keeps-comments-of-other-revisions-apart ()
  "Comments on one file against different revisions are quoted apart, each
with its own file line."
  (let* ((set (change-review-mail-test--set))
         (a (change-review-mail-test--add set "a.el" 'new 1 "On the old one." "@@ -1,1 +1,1 @@\n (setq a1 1)"
                                          :revision "older"))
         (b (change-review-mail-test--add set "a.el" 'new 1 "On the new one." "@@ -1,1 +1,1 @@\n (setq a1 1)")))
    (should (= 2 (cl-count ?d (apply #'concat (mapcar (lambda (l) (if (string-prefix-p "> diff" l) "d" ""))
                                                       (split-string (change-review-mail-render-comments set (list a b)) "\n"))))))))

;;;; Reading a reply

(ert-deftest change-review-mail-reads-the-quote-the-box-once-wrote ()
  "The text the review once put in a box reads back: the comments, the
sides and lines they are on, the files with their renames, the excerpts
with their headers counting just the lines quoted."
  (let ((blocks (change-review-mail-parse-reply change-review-mail-test--review-text :split t)))
    (should (equal '(("a.el" nil "Split this up") ("a.el" 2 "Why two?") ("a.el" 12 "Too far")
                     ("a.el" 18 "Why eighteen?") ("a.el" 18 "And the tests?") ("a.el" 20 "And twenty?")
                     ("b.el" 3 "Who used b3?") ("d.el" 6 "Six?") ("new.el" nil "Needs a test"))
                   (mapcar (lambda (b) (list (plist-get b :path) (plist-get b :line) (plist-get b :body))) blocks)))
    (should (equal '(new new new new new new old new new) (mapcar (lambda (b) (plist-get b :side)) blocks)))
    (should (equal '(nil nil t nil nil nil nil nil nil) (mapcar (lambda (b) (plist-get b :approx)) blocks)))
    (should (equal "c.el" (plist-get (nth 7 blocks) :old-path)))
    (should-not (plist-get (car blocks) :old-path))
    (should (equal "diff --git a/c.el b/d.el" (plist-get (nth 7 blocks) :file)))
    (should (equal "@@ -1,2 +1,2 @@\n (setq a1 1)\n-(setq a2 2)\n+(setq a2 'two)" (plist-get (nth 1 blocks) :excerpt)))
    (should (equal change-review-mail-test--a18 (plist-get (nth 3 blocks) :excerpt)))
    ;; Up to eight lines of the quote above: its header counts just those.
    (should (equal (concat "@@ -15,6 +15,6 @@\n (setq a15 15)\n (setq a16 16)\n (setq a17 17)\n"
                           "-(setq a18 18)\n+(setq a18 'eighteen)\n (setq a19 19)\n (setq a20 20)")
                   (plist-get (nth 5 blocks) :excerpt)))
    (should (equal "@@ -1,3 +0,0 @@\n-(setq b1 1)\n-(setq b2 2)\n-(setq b3 3)" (plist-get (nth 6 blocks) :excerpt)))
    (should-not (plist-get (nth 8 blocks) :excerpt))
    (should (equal "diff --git a/a.el b/a.el" (plist-get (car blocks) :file)))
    ;; The attribution is no comment.
    (should-not (cl-some (lambda (b) (string-search "My comments" (plist-get b :body))) blocks))
    (should (equal "0123456" (change-review-mail-parse-tip change-review-mail-test--review-text)))
    (should-not (change-review-mail-parse-tip "no hash here (at nothing)"))))

(defconst change-review-mail-test--round
  (concat "Nearly there.\n\n"
          change-review-mail-test--attribution "\n\n"
          "> diff --git a/a.el b/a.el\n"
          "> @@ -1,2 +1,2 @@\n"
          ">  (setq a1 1)\n"
          "> -(setq a2 2)\n"
          "> +(setq a2 'two)\n"
          "\n"
          "Why two?\n"
          "\n"
          "> diff --git a/docs/é.txt b/docs/é.txt\n"
          "\n"
          "Needs a caption\n")
  "A round of feedback of the kind a review once wrote in its box.")

(ert-deftest change-review-mail-reads-a-round-of-feedback ()
  "A round of feedback: words of the reviewer's own first, the line that says
what the quote is, then the quote with the comments under it."
  (let ((blocks (change-review-mail-parse-reply change-review-mail-test--round :split t)))
    (should (equal '(nil "a.el" "docs/é.txt") (mapcar (lambda (b) (plist-get b :path)) blocks)))
    (should (equal '("Nearly there." "Why two?" "Needs a caption")
                   (mapcar (lambda (b) (plist-get b :body)) blocks)))
    (should (equal '(nil 2 nil) (mapcar (lambda (b) (plist-get b :line)) blocks)))
    (should (equal "@@ -1,2 +1,2 @@\n (setq a1 1)\n-(setq a2 2)\n+(setq a2 'two)" (plist-get (nth 1 blocks) :excerpt)))
    (should (equal "0123456" (change-review-mail-parse-tip change-review-mail-test--round)))))

(ert-deftest change-review-mail-tells-an-attribution-from-a-sentence ()
  "Lines that say who is quoted are left out, however a mail client wrote
them, but a sentence of the reviewer's that looks a little like one stays."
  (pcase-dolist (`(,line . ,attribution)
                 '(("On Mon, Oct 19, 2026 at 10:36 PM Ann Author <ann@example.org> wrote:" . t)
                   ("On 2026-10-19 22:36, Ann Author wrote:" . t)
                   ("Ann Author <ann@example.org> writes:" . t)
                   ("<ann@example.org> wrote:" . t)
                   ("-----Original Message-----" . t)
                   ("On Mon, Oct 19, 2026 at 10:36:52PM -0400," . t)
                   ("On balance, this is fine." . nil)
                   ("On second thought," . nil)
                   ("She wrote a test." . nil)))
    (ert-info (line)
      (let ((blocks (change-review-mail-parse-reply (concat line "\n> diff --git a/x b/x\n> @@ -1 +1 @@\n> +a\nOk.\n"))))
        (should (equal (if attribution '("Ok.") (list line "Ok."))
                       (mapcar (lambda (b) (plist-get b :body)) blocks)))))))

(ert-deftest change-review-mail-reads-the-lines-numbers-across-comments ()
  "The numbers of a hunk go on across the comments in it, the lines of the
old file and the new apart; a removed line is of the old file."
  (let ((blocks (change-review-mail-parse-reply
                 (change-review-mail-test--text
                  "General words"
                  "> diff --git a/x b/x"
                  "> index 1..2 100644"
                  "> --- a/x"
                  "> +++ b/x"
                  "> @@ -3,3 +3,4 @@ (defun x ()"
                  ">  one"
                  "> -two"
                  "> +deux"
                  ""
                  "A comment"
                  ""
                  "> +trois"
                  ">  three"
                  "> @@ -10 +11 @@"
                  "> -ten"
                  "> +dix"
                  "> \\ No newline at end of file"
                  "Another"
                  ""
                  "> -ten again"
                  ""
                  "On the removed one")
                 :split t)))
    (should (equal '(nil "x" "x" "x") (mapcar (lambda (b) (plist-get b :path)) blocks)))
    (should (equal '("General words" "A comment" "Another" "On the removed one")
                   (mapcar (lambda (b) (plist-get b :body)) blocks)))
    (should (equal '(nil 4 11 11) (mapcar (lambda (b) (plist-get b :line)) blocks)))
    ;; The comment under the line that marks a missing newline is on the
    ;; line before it.
    (should (equal '(new new new old) (mapcar (lambda (b) (plist-get b :side)) blocks)))
    (should (equal "@@ -3,2 +3,2 @@ (defun x ()\n one\n-two\n+deux" (plist-get (nth 1 blocks) :excerpt)))
    (should (equal "@@ -10,1 +11,1 @@\n-ten\n+dix\n\\ No newline at end of file" (plist-get (nth 2 blocks) :excerpt)))))

(ert-deftest change-review-mail-reads-a-quote-that-goes-on-after-a-comment ()
  "The quote of a hunk may stop for a comment and go on: the lines after
the comment are numbered on from the lines before it."
  (let ((blocks (change-review-mail-parse-reply
                 (change-review-mail-test--text
                  "> diff --git a/x b/x"
                  "> @@ -1,3 +1,3 @@"
                  ">  a"
                  "> -b"
                  "> +B"
                  "Why?"
                  ">  c"
                  "Fine.")
                 :split t)))
    (should (equal '(("Why?" 2) ("Fine." 3)) (mapcar (lambda (b) (list (plist-get b :body) (plist-get b :line))) blocks)))
    (should (equal "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c" (plist-get (cadr blocks) :excerpt)))))

(ert-deftest change-review-mail-a-blank-line-ends-a-comment-only-when-asked ()
  "The paragraphs under a quote are one comment, or with SPLIT one each."
  (let ((text (change-review-mail-test--text
               "> diff --git a/x b/x"
               "> @@ -1,1 +1,1 @@"
               "> +a"
               ""
               "First thought."
               ""
               "Second thought."
               ""
               "> +b"
               "Third.")))
    (should (equal '("First thought.\n\nSecond thought." "Third.")
                   (mapcar (lambda (b) (plist-get b :body)) (change-review-mail-parse-reply text))))
    (should (equal '("First thought." "Second thought." "Third.")
                   (mapcar (lambda (b) (plist-get b :body)) (change-review-mail-parse-reply text :split t))))))

(ert-deftest change-review-mail-reads-a-reply-from-a-mail-client ()
  "A reply from a mail client: who is quoted is told, a quote of a quote and
text that is no diff are left out, an elision makes the numbers unknown
until the next hunk header, and the signature is cut."
  (let* ((message (change-review-mail-parse-message change-review-mail-test--reply-mail))
         (blocks (change-review-mail-parse-reply (plist-get message :body))))
    (should (equal "Bob Reviewer" (plist-get message :from-name)))
    (should (= 1 (length blocks)))
    (let ((block (car blocks)))
      (should (equal "a.txt" (plist-get block :path)))
      (should (equal "diff --git a/a.txt b/a.txt" (plist-get block :file)))
      (should (eq 'new (plist-get block :side)))
      ;; Under the line " ten" of the second hunk, after an elision.
      (should (eql 10 (plist-get block :line)))
      (should (equal (concat "@@ -8,3 +8,3 @@\n eight\n-nine\n+NINE\n ten") (plist-get block :excerpt)))
      (should (string-prefix-p "Why shout \"nine\"? It reads like a constant." (plist-get block :body)))
      (should (string-suffix-p "Looks good otherwise.\n\nThanks,\nBob" (plist-get block :body)))
      (should-not (string-search "Bob Reviewer" (plist-get block :body)))
      (should-not (string-search "wrote:" (plist-get block :body))))))

(ert-deftest change-review-mail-a-quote-between-two-answers-parts-them ()
  "Text the reviewer quoted between two paragraphs of theirs makes two
comments: the second answers the quote."
  (let ((blocks (change-review-mail-parse-reply
                 (change-review-mail-test--text
                  "> diff --git a/x b/x" "> @@ -1,1 +1,1 @@" "> +a"
                  "First."
                  "> > an earlier reply, nested"
                  ">"
                  "Second."))))
    (should (equal '("First." "Second.") (mapcar (lambda (b) (plist-get b :body)) blocks)))
    (should (equal '(1 1) (mapcar (lambda (b) (plist-get b :line)) blocks)))))

(ert-deftest change-review-mail-reads-what-it-can-after-an-elision ()
  "A comment right after an elision, before any hunk header, is on the file:
the lines it was under cannot be numbered."
  (let ((blocks (change-review-mail-parse-reply
                 (change-review-mail-test--text
                  "> diff --git a/x b/x"
                  "> @@ -1,3 +1,3 @@"
                  ">  a"
                  "> [...]"
                  ">  z"
                  ""
                  "Somewhere down there."
                  ""
                  "> @@ -50,2 +50,2 @@"
                  ">  q"
                  ""
                  "Here."))))
    (should (equal '(("x" nil nil "Somewhere down there.") ("x" 50 t "Here.")) 
                   (mapcar (lambda (b) (list (plist-get b :path) (plist-get b :line)
                                             (and (plist-get b :excerpt) t) (plist-get b :body)))
                           blocks)))))

(ert-deftest change-review-mail-tells-the-quote-from-prose ()
  "Quoted lines of a message that are no diff do not make a comment's place,
and are kept as what the comment answers."
  (let ((blocks (change-review-mail-parse-reply
                 (change-review-mail-test--text
                  "> Is this the one that crashed?"
                  ""
                  "Yes."
                  ""
                  "> diff --git a/x b/x"
                  "> @@ -1,1 +1,1 @@"
                  "> +a"
                  "> A remark in the quote"
                  "Fine."))))
    (should (equal '(nil "x") (mapcar (lambda (b) (plist-get b :path)) blocks)))
    (should (equal '("Yes." "Fine.") (mapcar (lambda (b) (plist-get b :body)) blocks)))
    (should (equal '("Is this the one that crashed?") (plist-get (car blocks) :prose)))
    (should (equal '("A remark in the quote") (plist-get (cadr blocks) :prose)))
    (should (equal "@@ -0,0 +1,1 @@\n+a" (plist-get (cadr blocks) :excerpt)))))

(ert-deftest change-review-mail-reads-paths-as-git-writes-them ()
  "A path with spaces, a quoted path and a rename are read from the line."
  (pcase-dolist (`(,line . ,expected)
                 '(("diff --git a/my file.el b/my file.el" . ("my file.el" . "my file.el"))
                   ("diff --git a/c.el b/d.el" . ("c.el" . "d.el"))
                   ("diff --git \"a/caf\\303\\251.txt\" \"b/caf\\303\\251.txt\"" . ("café.txt" . "café.txt"))
                   ("diff --git a/x\\ty b/x\\ty" . ("x\\ty" . "x\\ty"))
                   ("diff --git \"a/q\\\"uote\" \"b/q\\\"uote\"" . ("q\"uote" . "q\"uote"))))
    (ert-info (line)
      (should (equal expected (change-review-mail--header-paths line)))))
  (should-not (change-review-mail--header-paths "not a header")))

(ert-deftest change-review-mail-reads-the-patch-of-a-series-a-quote-names ()
  "A quoted line that names a patch of a series gives that number to the
comments after it, until another does."
  (let ((blocks (change-review-mail-parse-reply
                 (change-review-mail-test--text
                  "> [PATCH 1/3] a: shout two and nine"
                  "> diff --git a/a.txt b/a.txt"
                  "> @@ -1,2 +1,2 @@"
                  "> -two"
                  "> +TWO"
                  "Why?"
                  "> [PATCH 3/3] c: add a file"
                  "> diff --git a/c.txt b/c.txt"
                  "> @@ -0,0 +1 @@"
                  "> +new file"
                  "Ok."))))
    (should (equal '(1 3) (mapcar (lambda (b) (plist-get b :patch)) blocks)))
    (should (equal '("a.txt" "c.txt") (mapcar (lambda (b) (plist-get b :path)) blocks)))
    (should (equal "@@ -0,0 +1,1 @@\n+new file" (plist-get (cadr blocks) :excerpt)))))

(ert-deftest change-review-mail-writing-and-reading-agree ()
  "What is written reads back: the places, the sides, the text, with the
lines of the old file and of the new."
  (let* ((set (change-review-mail-test--set))
         (added (change-review-mail-test--add set "a.el" 'new 3 "On the added one."
                                              "@@ -1,2 +1,3 @@\n (setq a1 1)\n (setq a2 2)\n+(setq a3 'new)"))
         (removed (change-review-mail-test--add set "a.el" 'old 5 "On the removed one."
                                                "@@ -4,2 +5,1 @@\n (setq a4 4)\n-(setq a5 5)"))
         (context (change-review-mail-test--add set "d.el" 'new 9 "On the context one."
                                                 "@@ -9,1 +9,1 @@ (defun d ()\n (setq d9 9)"))
         (blocks (change-review-mail-parse-reply
                  (change-review-mail-render-comments set (list added removed context)) :split t)))
    (should (equal '(("a.el" new 3 "On the added one.") ("a.el" old 5 "On the removed one.")
                     ("d.el" new 9 "On the context one."))
                   (mapcar (lambda (b) (list (plist-get b :path) (plist-get b :side) (plist-get b :line) (plist-get b :body)))
                           blocks)))
    (should (equal (mapcar (lambda (c) (change-review-location-excerpt (change-review-comment-location c)))
                           (list added removed context))
                   (mapcar (lambda (b) (plist-get b :excerpt)) blocks)))
    ;; A line the quote ends before: the prefix reads back as the line.
    (let* ((far (change-review-mail-test--add set "a.el" 'old 30 "Past the end."
                                              "@@ -19,2 +19,2 @@\n (setq a19 19)\n (setq a20 20)"))
           (block (car (change-review-mail-parse-reply (change-review-mail-render-comments set (list far))))))
      (should (equal '(old 30 t "Past the end.") (list (plist-get block :side) (plist-get block :line)
                                                       (plist-get block :approx) (plist-get block :body))))
      (should (equal "@@ -19,2 +19,2 @@\n (setq a19 19)\n (setq a20 20)" (plist-get block :excerpt))))))

;;;; Importing a reply

(defun change-review-mail-test--imported-set ()
  "Return a set with the series of the tests imported."
  (let ((set (change-review-make-set :id "mailed")))
    (change-review-mail-import-patches set change-review-mail-test--series)
    set))

(ert-deftest change-review-mail-imports-a-reply-as-comments ()
  "A reply mail makes comments of its author, at its time, already sent,
with the places they are under; importing it again adds nothing."
  (let* ((set (change-review-mail-test--imported-set))
         (comments (change-review-mail-import-reply-message set change-review-mail-test--reply-mail)))
    (should (= 1 (length comments)))
    (let* ((comment (car comments))
           (thread (car (change-review-find-comment set (change-review-comment-id comment))))
           (location (change-review-comment-location comment)))
      (should (equal "Bob Reviewer" (change-review-author-name (change-review-comment-author comment))))
      (should (equal "bob@example.org" (change-review-author-email (change-review-comment-author comment))))
      (should (eq 'user (change-review-author-kind (change-review-comment-author comment))))
      (should (numberp (change-review-comment-time comment)))
      (should (eql (change-review-comment-time comment) (change-review-comment-sent comment)))
      (should-not (change-review-comment-draft-p comment))
      (should (equal "a.txt" (change-review-location-file location)))
      (should (eql 10 (change-review-location-line location)))
      (should (eq 'new (change-review-location-side location)))
      (should (equal "@@ -8,3 +8,3 @@\n eight\n-nine\n+NINE\n ten" (change-review-location-excerpt location)))
      ;; The reply was to the first patch of the series.
      (should (eql 1 (change-review-location-patch location)))
      (should (equal "<r1@example.org>" (plist-get (change-review-comment-meta comment) :message-id)))
      (should (equal "<p1-1@example.org>" (plist-get (change-review-comment-meta comment) :in-reply-to)))
      (should (eq 'open (change-review-thread-status thread)))
      ;; Against the only version there is.
      (should (equal "<cover-1@example.org>" (change-review-comment-revision comment)))
      (should (equal "<cover-1@example.org>" (change-review-thread-revision thread))))
    (let ((again (change-review-mail-import-reply-message set change-review-mail-test--reply-mail)))
      (should (equal (mapcar #'change-review-comment-id comments) (mapcar #'change-review-comment-id again)))
      (should (= 1 (length (change-review-set-threads set))))
      (should (= 1 (length (change-review-thread-comments (car (change-review-set-threads set)))))))))

(ert-deftest change-review-mail-does-not-take-a-patch-for-a-reply ()
  "A patch mail is no reply: it makes no comment."
  (let ((set (change-review-mail-test--imported-set)))
    (should-not (change-review-mail-import-reply-message set change-review-mail-test--patch-1))
    (should-not (change-review-set-threads set))))

(ert-deftest change-review-mail-import-uses-the-commit-a-review-names ()
  "The version a reply says it is of -- \"(at HASH)\" -- is the revision of
its comments, else the newest."
  (let* ((set (change-review-make-set))
         (_ (change-review-add-version set (change-review-make-version :id "aaaa111" :tip "aaaa1111111")))
         (_ (change-review-add-version set (change-review-make-version :id "bbbb222" :tip "bbbb2222222")))
         (text (concat "My comments on the diff of your branch t (at aaaa111) against main (merge base bbbb222), each under the lines it is about:\n\n"
                       "> diff --git a/x b/x\n> @@ -1 +1 @@\n> +a\n\nHm.\n"))
         (comment (car (change-review-mail-import-reply set text :message-id "<m1>")))
         (other (car (change-review-mail-import-reply
                      set "> diff --git a/x b/x\n> @@ -1 +1 @@\n> +a\n\nHm.\n" :message-id "<m2>")))
         (given (car (change-review-mail-import-reply
                      set "> diff --git a/x b/x\n> @@ -1 +1 @@\n> +a\n\nHm.\n" :message-id "<m3>" :revision "aaaa111"))))
    (should (equal "aaaa111" (change-review-comment-revision comment)))
    (should (equal "bbbb222" (change-review-comment-revision other)))
    (should (equal "aaaa111" (change-review-comment-revision given)))
    (should (equal "Hm." (change-review-comment-body comment)))))

(ert-deftest change-review-mail-a-reply-to-a-reply-joins-its-thread ()
  "A reply mail that answers a mail whose comments are in the set joins the
thread of the comment it answers: by the line it is under, by the text it
quotes, or when it answers a single comment."
  (let* ((set (change-review-make-set))
         (_ (change-review-add-version set (change-review-make-version :id "tip")))
         (alice (change-review-user "Alice" "alice@example.org"))
         (text (change-review-mail-test--text
                "> diff --git a/x b/x" "> @@ -1,2 +1,2 @@" ">  a" "> +b" "First point."
                "> @@ -9,2 +9,2 @@" ">  y" "> +z" "Second point."))
         (comments (change-review-mail-import-reply set text :author alice :time 10 :message-id "<alice@x>")))
    (should (= 2 (length comments)))
    (should (= 2 (length (change-review-set-threads set))))
    ;; By the line: Bob quotes the diff again and answers under the second.
    (let ((reply (change-review-mail-import-reply
                  set (change-review-mail-test--text "> diff --git a/x b/x" "> @@ -9,2 +9,2 @@" ">  y" "> +z" "I disagree.")
                  :author (change-review-user "Bob") :time 20 :message-id "<bob1@x>" :in-reply-to "<alice@x>")))
      (should (= 2 (length (change-review-set-threads set))))
      (let* ((comment (car reply))
             (thread (car (change-review-find-comment set (change-review-comment-id comment)))))
        (should (equal (change-review-comment-thread (cadr comments)) (change-review-thread-id thread)))
        (should (equal (change-review-comment-id (cadr comments)) (change-review-comment-reply-to comment)))
        (should-not (change-review-comment-location comment))
        (should (equal '("Second point." "I disagree.")
                       (mapcar #'change-review-comment-body (change-review-thread-comments thread))))))
    ;; By the text it quotes: no diff, Alice's words in the quote.
    (let ((reply (change-review-mail-import-reply
                  set (change-review-mail-test--text "> > diff --git a/x b/x" "> First point." "" "Done.")
                  :author (change-review-user "Bob") :time 30 :message-id "<bob2@x>" :in-reply-to "<alice@x>")))
      (should (equal (change-review-comment-thread (car comments))
                     (change-review-comment-thread (car reply)))))
    ;; Answering one comment only: whatever is said is a reply to it.
    (let* ((only (change-review-mail-import-reply
                  set "> diff --git a/y b/y\n> @@ -1 +1 @@\n> +q\nOne point.\n" :author alice :time 40 :message-id "<alice2@x>"))
           (reply (change-review-mail-import-reply set "Fixed, thanks.\n" :author (change-review-user "Bob") :time 50
                                                   :message-id "<bob3@x>" :in-reply-to "<alice2@x>")))
      (should (equal (change-review-comment-thread (car only)) (change-review-comment-thread (car reply)))))
    ;; Answering two, quoting nothing that tells which: a thread of its own.
    (let ((reply (change-review-mail-import-reply set "Thanks all.\n" :author (change-review-user "Bob") :time 60
                                                  :message-id "<bob4@x>" :in-reply-to "<alice@x>")))
      (should-not (member (change-review-comment-thread (car reply))
                          (mapcar #'change-review-comment-thread comments))))
    ;; Answering no mail the set has: a thread of its own.
    (let ((before (length (change-review-set-threads set))))
      (change-review-mail-import-reply set "Hello.\n" :author alice :time 70 :message-id "<alice3@x>"
                                       :in-reply-to "<nobody@x>")
      (should (= (1+ before) (length (change-review-set-threads set)))))))

(ert-deftest change-review-mail-the-caller-can-name-the-thread ()
  "A function of the comment names the thread it joins."
  (let* ((set (change-review-make-set))
         (root (change-review-comment set "Root." :author (change-review-user "A") :time 1 :sent 1))
         (thread-id (change-review-comment-thread root))
         (reply (car (change-review-mail-import-reply
                      set "Joined.\n" :author (change-review-user "B") :time 2 :message-id "<m>"
                      :thread-id-fn (lambda (_block) thread-id)))))
    (should (equal thread-id (change-review-comment-thread reply)))
    (should (equal (change-review-comment-id root) (change-review-comment-reply-to reply)))
    ;; A name no thread has starts a thread of that name.
    (let ((new (car (change-review-mail-import-reply
                     set "Elsewhere.\n" :author (change-review-user "B") :time 3 :message-id "<n>"
                     :thread-id-fn (lambda (_block) "t-chosen")))))
      (should (equal "t-chosen" (change-review-comment-thread new))))))

(ert-deftest change-review-mail-imports-the-comments-of-a-reply-apart-or-together ()
  "Paragraphs under one quote are one comment, or with SPLIT one each."
  (let ((set (change-review-make-set))
        (text (change-review-mail-test--text "> diff --git a/x b/x" "> @@ -1 +1 @@" "> +a" "" "One." "" "Two.")))
    (should (= 1 (length (change-review-mail-import-reply set text :message-id "<m1>"))))
    (should (= 2 (length (change-review-mail-import-reply set text :message-id "<m2>" :split t))))))

;;;; Writing a reply mail

(ert-deftest change-review-mail-writes-a-reply-mail ()
  "A reply mail has the headers of a reply to the first mail of the version
and the text of the comments."
  (let* ((set (change-review-make-set :id "mailed"))
         (versions (change-review-mail-import-patches set change-review-mail-test--series))
         (_ (ignore versions))
         (comment (change-review-comment
                   set "Why shout?" :author (change-review-user "Bob Reviewer" "bob@example.org") :time 5
                   :location (change-review-make-location :file "a.txt" :line 2 :patch 1
                                                          :excerpt "@@ -1,2 +1,2 @@\n one\n-two\n+TWO")))
         (mail (unwind-protect
                   (progn
                     (set-time-zone-rule t)
                     (cl-letf (((symbol-function 'change-review-current-author)
                                (lambda (_set) (change-review-user "Bob Reviewer" "bob@example.org"))))
                       (change-review-mail-reply-message set :date (encode-time 0 0 12 20 10 2026 t)
                                                         :attribution "Attributed:")))
                 (set-time-zone-rule nil)))
         (separator (string-search "\n\n" mail))
         (headers (substring mail 0 separator)))
    (should (string-search "From: Bob Reviewer <bob@example.org>\n" (concat headers "\n")))
    (should (string-search "To: Ann Author <ann@example.org>\n" (concat headers "\n")))
    (should (string-search "Subject: Re: [PATCH 0/3] Shout in a.txt and grow b.txt\n" (concat headers "\n")))
    (should (string-search "In-Reply-To: <cover-1@example.org>\n" (concat headers "\n")))
    (should (string-search "References: <cover-1@example.org>\n" (concat headers "\n")))
    (should (string-search "Date: Tue, 20 Oct 2026 12:00:00 +0000\n" (concat headers "\n")))
    (should (string-search "Content-Type: text/plain; charset=utf-8\n" (concat headers "\n")))
    (should-not (string-search "Cc:" headers))
    (should (equal (concat "Attributed:\n\n> diff --git a/a.txt b/a.txt\n> @@ -1,2 +1,2 @@\n>  one\n> -two\n> +TWO\n\nWhy shout?\n")
                   (substring mail (+ separator 2))))
    ;; The mail reads as a mail.
    (let ((parsed (change-review-mail-parse-message mail)))
      (should (equal "Bob Reviewer" (plist-get parsed :from-name)))
      (should (equal "Re: [PATCH 0/3] Shout in a.txt and grow b.txt" (plist-get parsed :subject)))
      (should (equal "<cover-1@example.org>" (plist-get parsed :in-reply-to))))
    (should (change-review-comment-draft-p comment))))

(ert-deftest change-review-mail-writes-a-reply-mail-for-each-patch ()
  "The comments on each patch of a series are a mail of their own, in reply
to that patch; the ones on none are in reply to the cover letter."
  (let* ((set (change-review-make-set :id "mailed"))
         (_ (change-review-mail-import-patches set change-review-mail-test--series))
         (me (change-review-user "Bob Reviewer" "bob@example.org")))
    (change-review-comment set "On patch 1." :author me :time 1
                           :location (change-review-make-location :file "a.txt" :line 2 :patch 1
                                                                  :excerpt "@@ -1,3 +1,3 @@\n one\n-two\n+TWO"))
    (change-review-comment set "On patch 2." :author me :time 2
                           :location (change-review-make-location :file "b.txt" :line 3 :patch 2
                                                                  :excerpt "@@ -1,2 +1,3 @@\n alpha\n beta\n+gamma"))
    (change-review-comment set "In general." :author me :time 3)
    (let ((messages (change-review-mail-reply-messages set :from me :to "list@example.org" :cc '("c@example.org" "d@example.org"))))
      (should (equal '(1 2 nil) (mapcar #'car messages)))
      (let ((one (change-review-mail-parse-message (cdr (nth 0 messages))))
            (general (change-review-mail-parse-message (cdr (nth 2 messages)))))
        (should (equal "Re: [PATCH 1/3] a: shout two and nine" (plist-get one :subject)))
        (should (equal "<p1-1@example.org>" (plist-get one :in-reply-to)))
        (should (equal '("<cover-1@example.org>" "<p1-1@example.org>") (plist-get one :references)))
        (should (equal "list@example.org" (plist-get one :to)))
        (should (equal "c@example.org, d@example.org" (plist-get one :cc)))
        (should (string-search "On patch 1." (plist-get one :body)))
        (should-not (string-search "On patch 2." (plist-get one :body)))
        (should (equal "<cover-1@example.org>" (plist-get general :in-reply-to)))
        (should (equal "In general." (plist-get general :body)))))
    (should (string-search "On patch 2." (change-review-mail-reply-message set :patch 2)))
    (should-not (string-search "On patch 1." (change-review-mail-reply-message set :patch 2)))))

(ert-deftest change-review-mail-composes-a-reply-and-marks-it-sent ()
  "The reply opens in a mail buffer, headers parted from the text by the
mail header separator; once it is sent its comments are sent."
  (require 'message)
  (let* ((set (change-review-make-set :id "mailed"))
         (_ (change-review-mail-import-patches set change-review-mail-test--series))
         (comment (change-review-comment set "Hm." :author (change-review-user "Bob" "bob@example.org") :time 1))
         buffers)
    (unwind-protect
        (cl-letf (((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) buffer)))
          (setq buffers (change-review-mail-compose set :from (change-review-user "Bob" "bob@example.org")))
          (should (= 1 (length buffers)))
          (with-current-buffer (car buffers)
            (should (derived-mode-p 'message-mode))
            (goto-char (point-min))
            (should (search-forward (concat "\n" mail-header-separator "\n") nil t))
            (should (equal "Hm.\n" (buffer-substring (point) (point-max))))
            (should (change-review-comment-draft-p comment))
            (run-hooks 'message-sent-hook)
            (should-not (change-review-comment-draft-p comment))
            (should (plist-get (change-review-comment-meta comment) :mailed))))
      (mapc #'kill-buffer buffers))
    (should-error (change-review-mail-compose (change-review-make-set)) :type 'user-error)))

;;;; The library compiles

(ert-deftest change-review-mail-compiles-without-a-warning ()
  "The library byte-compiles without a warning."
  (let* ((dir (make-temp-file "change-review-mail-elc" t))
         (byte-compile-dest-file-function (lambda (_) (expand-file-name "change-review-mail.elc" dir)))
         (byte-compile-error-on-warn t)
         (load-path (cons change-review-mail-test--directory load-path)))
    (unwind-protect
        (should (byte-compile-file (expand-file-name "change-review-mail.el" change-review-mail-test--directory)))
      (delete-directory dir t))))

(provide 'change-review-mail-test)
;;; change-review-mail-test.el ends here
