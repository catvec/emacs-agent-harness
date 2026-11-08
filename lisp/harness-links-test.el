;;; harness-links-test.el --- Tests for how a harness link reads and is written  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; harness-links.el is pure: it knows the syntax of a link, and where one
;; stands in Markdown text, not what it names.  So these tests need no
;; harness, only the file.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-links)

;;;; Reading

(ert-deftest harness-links-parse-reads-every-shape ()
  "A link reads as the thing it names, and the session or task it is under."
  (pcase-dolist (`(,url ,expected)
                 '(("harness:session/abc" (:kind session :session "abc"))
                   ("harness:session/abc/message/n-1" (:kind message :session "abc" :message "n-1"))
                   ("harness:session/abc/call/n-2" (:kind call :session "abc" :call "n-2"))
                   ("harness:session/abc/thread/t-3" (:kind thread :session "abc" :thread "t-3"))
                   ("harness:message/n-1" (:kind message :message "n-1"))
                   ("harness:call/n-2" (:kind call :call "n-2"))
                   ("harness:call/toolu_01AbC" (:kind call :call "toolu_01AbC"))
                   ("harness:thread/t-3" (:kind thread :thread "t-3"))
                   ("harness:task/t-4" (:kind task :task "t-4"))
                   ("harness:task/t-4/thread/t-3" (:kind thread :task "t-4" :thread "t-3"))))
    (ert-info (url)
      (should (equal expected (harness-links-parse url))))))

(ert-deftest harness-links-parse-takes-the-names-a-model-may-write ()
  "A kind goes by its other names, in any case; slashes after the scheme and at the end are ignored."
  (should (equal '(:kind message :message "n-1") (harness-links-parse "harness:msg/n-1")))
  (should (equal '(:kind message :message "n-1") (harness-links-parse "harness:node/n-1")))
  (dolist (name '("tool-call" "tool_call" "toolcall" "tool" "Call" "CALL"))
    (should (equal '(:kind call :call "last") (harness-links-parse (concat "harness:" name "/last")))))
  (should (equal '(:kind session :session "abc") (harness-links-parse "HARNESS:Session/abc")))
  (should (equal '(:kind session :session "abc") (harness-links-parse "harness://session/abc/")))
  (should (equal '(:kind session :session "abc") (harness-links-parse "  harness:session/abc  "))))

(ert-deftest harness-links-parse-decodes-the-refs ()
  "A ref is written %XX where a URL could not carry it, and read back as UTF-8."
  (should (equal "My session (2)" (plist-get (harness-links-parse "harness:session/My%20session%20%282%29")
                                             :session)))
  (should (equal "a/b" (plist-get (harness-links-parse "harness:session/a%2Fb") :session)))
  (should (equal "café" (plist-get (harness-links-parse "harness:session/caf%C3%A9") :session)))
  ;; A broken escape is left as it is.
  (should (equal "50%" (plist-get (harness-links-parse "harness:session/50%") :session))))

(ert-deftest harness-links-parse-refuses-what-names-nothing ()
  (dolist (url '("harness:" "harness:/" "harness:session" "harness:session/" "harness:session//x"
                 "harness:session/a/b" "harness:foo/bar" "harness:session/a/message"
                 "harness:message/a/session/b" "harness:call/a/call/b" "harness:thread/a/task/b"
                 "harness:task/a/session/b" "harness:task/a/message/b"
                 "https://example.org/session/abc" "session/abc" "" nil 12))
    (ert-info ((format "%S" url))
      (should-not (harness-links-parse url)))))

(ert-deftest harness-links-p-is-only-the-scheme ()
  (should (harness-links-p "harness:session/abc"))
  (should (harness-links-p "HARNESS:nonsense"))
  (should-not (harness-links-p "harness"))
  (should-not (harness-links-p "https://harness:8080"))
  (should-not (harness-links-p nil)))

(ert-deftest harness-links-parse-handle-reads-handles ()
  (should (equal '(:nth 1) (harness-links-parse-handle "last")))
  (should (equal '(:nth 1) (harness-links-parse-handle "Newest")))
  (should (equal '(:nth 1) (harness-links-parse-handle "latest")))
  (should (equal '(:first t) (harness-links-parse-handle "first")))
  (should (equal '(:first t) (harness-links-parse-handle "oldest")))
  (should (equal '(:nth 3) (harness-links-parse-handle "#3")))
  (should (equal '(:name "bash" :nth 2) (harness-links-parse-handle "bash#2")))
  (should (equal '(:name "user" :nth 1) (harness-links-parse-handle " user#1 ")))
  (should (equal '(:name "read_file" :nth 12) (harness-links-parse-handle "read_file#12")))
  (dolist (ref '("#0" "bash#0" "bash#" "bash" "n-abc1234567" "toolu_01#x" "" nil))
    (ert-info ((format "%S" ref))
      (should-not (harness-links-parse-handle ref)))))

;;;; Writing

(ert-deftest harness-links-url-writes-every-shape ()
  (should (equal "harness:session/abc" (harness-links-session-url "abc")))
  (should (equal "harness:session/abc/message/n-1" (harness-links-message-url "abc" "n-1")))
  (should (equal "harness:session/abc/call/n-2" (harness-links-call-url "abc" "n-2")))
  (should (equal "harness:message/n-1" (harness-links-message-url nil "n-1")))
  (should (equal "harness:call/bash#2" (harness-links-call-url nil "bash#2")))
  (should (equal "harness:task/t-4" (harness-links-task-url "t-4")))
  (should (equal "harness:task/t-4/thread/t-3" (harness-links-thread-url "t-4" "t-3")))
  (should (equal "harness:thread/t-3" (harness-links-thread-url nil "t-3")))
  (should (equal "harness:session/abc/thread/t-3"
                 (harness-links-url '(:kind thread :session "abc" :thread "t-3"))))
  ;; A thread under a task is written under it, whatever else is given.
  (should (equal "harness:task/t-4/thread/t-3"
                 (harness-links-url '(:kind thread :task "t-4" :session "abc" :thread "t-3")))))

(ert-deftest harness-links-url-names-nothing-from-too-little ()
  (should-not (harness-links-url '(:kind session)))
  (should-not (harness-links-url '(:kind message :session "abc")))
  (should-not (harness-links-url '(:kind call)))
  (should-not (harness-links-url '(:kind thread :task "t-4")))
  (should-not (harness-links-url '(:kind task :task "")))
  (should-not (harness-links-url '(:kind other :session "abc"))))

(ert-deftest harness-links-url-round-trips-through-parse ()
  "Whatever a ref holds, the URL carries it and reads back the same."
  (dolist (ref '("abc" "n-1234567890" "My session (2)" "a/b" "café" "50%" "x y#z" "[odd]<name>"
                 "a\"b" "100% sure?" "tab\there"))
    (ert-info ((format "%S" ref))
      (let ((url (harness-links-session-url ref)))
        ;; Nothing that would end a Markdown link, an autolink or a bare link early.
        (should-not (string-match-p "[][()<>\" \t\n`*?]" (substring url (length "harness:"))))
        (should (equal ref (plist-get (harness-links-parse url) :session)))
        (should (equal ref (plist-get (harness-links-parse (harness-links-message-url ref "n-1"))
                                      :session)))))))

(ert-deftest harness-links-markdown-keeps-brackets-out-of-the-label ()
  (should (equal "[the run](harness:call/last)" (harness-links-markdown "the run" "harness:call/last")))
  (should (equal "[a (b) c](harness:call/last)" (harness-links-markdown "a [b] c" "harness:call/last"))))

(ert-deftest harness-links-label-stands-in-for-the-words-of-an-autolink ()
  (should (equal "Fix the build" (harness-links-label '(:kind session :session "abc") "Fix the build")))
  (should (equal "session abc" (harness-links-label '(:kind session :session "abc"))))
  (should (equal "message n-1 of Fix" (harness-links-label '(:kind message :message "n-1") "Fix")))
  (should (equal "message n-1" (harness-links-label '(:kind message :message "n-1"))))
  (should (equal "tool call bash#2" (harness-links-label '(:kind call :call "bash#2"))))
  (should (equal "thread t-3" (harness-links-label '(:kind thread :thread "t-3"))))
  (should (equal "task t-4" (harness-links-label '(:kind task :task "t-4"))))
  (should (equal "Build" (harness-links-label '(:kind task :task "t-4") "Build")))
  ;; A long id is cut.
  (should (< (length (harness-links-label (list :kind 'call :call (make-string 80 ?x)))) 40)))

;;;; Finding links in text

(defun harness-links-test--urls (text)
  "Return the URLs of the links `harness-links-scan' finds in TEXT, with their form."
  (mapcar (lambda (link) (cons (plist-get link :form) (plist-get link :url)))
          (harness-links-scan text)))

(ert-deftest harness-links-scan-finds-the-three-forms ()
  (should (equal '((link . "harness:call/last")
                   (autolink . "harness:session/abc")
                   (bare . "harness:thread/t-3"))
                 (harness-links-test--urls
                  "See [the run](harness:call/last), <harness:session/abc> and harness:thread/t-3."))))

(ert-deftest harness-links-scan-gives-the-places ()
  "Each link says where it and its URL are, so a caller can change the URL alone."
  (let* ((text "a [the run]( harness:call/last ) b <harness:session/abc> c harness:task/t-4: d")
         (links (harness-links-scan text)))
    (should (= 3 (length links)))
    (pcase-dolist (`(,link ,form ,url)
                   `((,(nth 0 links) link "harness:call/last")
                     (,(nth 1 links) autolink "harness:session/abc")
                     (,(nth 2 links) bare "harness:task/t-4")))
      (should (eq form (plist-get link :form)))
      (should (equal url (plist-get link :url)))
      (should (equal url (substring text (plist-get link :url-start) (plist-get link :url-end)))))
    (should (equal "[the run]( harness:call/last )"
                   (substring text (plist-get (nth 0 links) :start) (plist-get (nth 0 links) :end))))
    (should (equal "the run" (plist-get (nth 0 links) :label)))
    (should (equal "<harness:session/abc>"
                   (substring text (plist-get (nth 1 links) :start) (plist-get (nth 1 links) :end))))
    ;; The colon that closes the sentence is not part of the link.
    (should (equal "harness:task/t-4"
                   (substring text (plist-get (nth 2 links) :start) (plist-get (nth 2 links) :end))))))

(ert-deftest harness-links-scan-leaves-code-alone ()
  "What the renderer shows as code holds no link."
  (should-not (harness-links-scan "`[x](harness:call/last)` and `harness:session/abc` and `<harness:task/t-1>`"))
  (should-not (harness-links-scan "text\n```\n[x](harness:call/last)\nharness:session/abc\n```\nmore"))
  (should-not (harness-links-scan "~~~sh\n[x](harness:call/last)\n~~~\n"))
  (should-not (harness-links-scan "```\nnever closed [x](harness:call/last)\n"))
  ;; An indented fence is one up to three spaces; the closing one must match.
  (should-not (harness-links-scan "  ```\n[x](harness:call/last)\n  ```\n"))
  (should (equal '((link . "harness:call/last"))
                 (harness-links-test--urls "```\n```\n[x](harness:call/last)\n")))
  ;; A shorter fence does not close a longer one.
  (should-not (harness-links-scan "````\n```\n[x](harness:call/last)\n````\n"))
  ;; Before and after a block they count.
  (should (equal '((link . "harness:call/1") (link . "harness:call/2"))
                 (harness-links-test--urls "[a](harness:call/1)\n```\n[x](harness:call/9)\n```\n[b](harness:call/2)"))))

(ert-deftest harness-links-scan-ignores-what-is-not-a-link ()
  (should-not (harness-links-scan "no links here"))
  (should-not (harness-links-scan ""))
  (should-not (harness-links-scan nil))
  (should-not (harness-links-scan "[web](https://example.org) and <https://example.org>"))
  ;; A scheme word on its own, a sentence, a bare URL that names no kind.
  (should-not (harness-links-scan "The harness: it runs. harness:foo/bar and the harness:8080"))
  ;; Inside a longer address or word, it is not a link of its own.
  (should-not (harness-links-scan "see https://example.org/harness:session/abc and xharness:session/abc")))

(ert-deftest harness-links-scan-keeps-the-order-and-the-text-between ()
  (let ((links (harness-links-scan "[a](harness:call/1) x [b](https://e.org) y [c](harness:call/3)")))
    (should (equal '("harness:call/1" "harness:call/3") (mapcar (lambda (l) (plist-get l :url)) links)))))

(ert-deftest harness-links-scan-takes-a-label-that-holds-code ()
  (should (equal '((link . "harness:call/last"))
                 (harness-links-test--urls "[`scripts/test.sh`](harness:call/last)"))))

;;;; Rewriting

(ert-deftest harness-links-rewrite-changes-the-urls-in-place ()
  (should (equal "a [x](harness:call/9) b <harness:session/ABC> c harness:thread/T"
                 (harness-links-rewrite
                  "a [x](harness:call/last) b <harness:session/abc> c harness:thread/t"
                  (lambda (link)
                    (pcase (plist-get link :form)
                      ('link "harness:call/9")
                      ('autolink "harness:session/ABC")
                      ('bare "harness:thread/T")))))))

(ert-deftest harness-links-rewrite-leaves-what-the-function-leaves ()
  (let ((text "[x](harness:call/last) and `[y](harness:call/last)`\n```\n[z](harness:call/last)\n```"))
    (should (eq text (harness-links-rewrite text #'ignore)))
    (should (equal text (harness-links-rewrite text (lambda (link) (plist-get link :url)))))
    ;; Only the first is a link, so only it changes.
    (should (equal (replace-regexp-in-string "\\`\\[x\\](harness:call/last)" "[x](harness:call/7)" text)
                   (harness-links-rewrite text (lambda (_) "harness:call/7"))))))

(ert-deftest harness-links-rewrite-keeps-the-spacing-of-a-padded-link ()
  (should (equal "[x]( harness:call/7 )"
                 (harness-links-rewrite "[x]( harness:call/last )" (lambda (_) "harness:call/7")))))

(ert-deftest harness-links-rewrite-turns-a-bare-link-into-a-markdown-one ()
  "A bare link has no more than its URL, so the function may put a whole link in its place."
  (should (equal "see [the run](harness:session/S/call/N)."
                 (harness-links-rewrite "see harness:call/last."
                                        (lambda (link)
                                          (and (eq 'bare (plist-get link :form))
                                               "[the run](harness:session/S/call/N)"))))))

(ert-deftest harness-links-scan-takes-time-linear-in-the-text ()
  "Text full of brackets, backquotes and angle brackets is read in time that grows with it."
  (let ((start (float-time)))
    (dolist (text (list (apply #'concat (make-list 20000 "[a "))
                        (apply #'concat (make-list 20000 "`a "))
                        (apply #'concat (make-list 20000 "<harness:x "))
                        (concat (apply #'concat (make-list 5000 "[a](b ")) "harness:call/x")))
      (harness-links-scan (concat "harness: " text)))
    (should (< (- (float-time) start) 20))))

(provide 'harness-links-test)
;;; harness-links-test.el ends here
