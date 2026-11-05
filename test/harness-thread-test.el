;;; harness-thread-test.el --- Tests for replies in threads: data, text and blocks  -*- lexical-binding: t; -*-

;;; Commentary:

;; A reply in a thread is a text block with the data of the thread
;; (harness-util.el): what the regions it answers are, and where they are
;; from.  These tests cover the data's shape, the text the agent reads, the
;; block, and the ways it travels: as an attachment of the compose box and
;; in the content of an ACP prompt.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defconst harness-thread-test--chat
  '(:kind "chat" :node "n-1" :who "agent" :from 4 :to 22 :text "The build is green.")
  "A reference to a part of a message of the agent's.")

(defconst harness-thread-test--link "harness:message/n-1"
  "The link to the node of `harness-thread-test--chat', which names no session.")

(defconst harness-thread-test--header
  (format "Your earlier message (%s):" harness-thread-test--link)
  "The line that opens the quote of `harness-thread-test--chat'.")

(defconst harness-thread-test--quoted-good
  (concat "> " harness-thread-test--header "\n>\n> The build is green.\n\nGood.")
  "The text of a reply, \"Good.\", to `harness-thread-test--chat'.")

(defconst harness-thread-test--diff
  '(:kind "diff" :file "lisp/a.el" :side "new" :line 18 :end 19 :revision "0123456789abcdef"
    :text "(setq a18 'eighteen)\n(setq a19 19)")
  "A reference to two lines of a diff.")

(ert-deftest harness-thread-quotes-the-references-the-way-a-mail-does ()
  "The text of a reply is the quote of each reference, with a header that says
where it is from and links the message, a blank line between two, the
response, and the thread's marker once the thread is a comment in a review."
  (let ((data (list :refs (list harness-thread-test--chat) :response "Good.")))
    (should (equal (concat "> " harness-thread-test--header "\n>\n> The build is green.\n\nGood.")
                   (harness-thread-text data)))
    (should (equal (concat "> " harness-thread-test--header
                           "\n>\n> The build is green.\n\nGood.\n\n[thread t-1a2b: answer with review_comment]")
                   (harness-thread-text (append data (list :id "t-1a2b"))))))
  ;; Several references: a quote each, and a multi-line quote line by line.
  (should (equal (concat "> Your earlier message (harness:message/n-1):\n>\n> One.\n>\n> More.\n\n"
                         "> Your earlier message (harness:message/n-2):\n>\n> Two.\n\nAll good.")
                 (harness-thread-text
                  (list :refs (list '(:kind "chat" :node "n-1" :who "agent" :text "One.\n\nMore.")
                                    '(:kind "chat" :node "n-2" :who "agent" :text "Two."))
                        :response "All good."))))
  ;; The user's own message, a diff and a buffer say where they are from.
  (should (equal "> My earlier message (harness:message/n-3):\n>\n> Check it.\n\nDone."
                 (harness-thread-text (list :refs '((:kind "chat" :node "n-3" :who "you" :text "Check it."))
                                            :response "Done."))))
  (should (equal (concat "> In lisp/a.el, lines 18-19 (after the change, at 01234567):\n>\n"
                         "> (setq a18 'eighteen)\n> (setq a19 19)\n\nWhy a symbol?")
                 (harness-thread-text (list :refs (list harness-thread-test--diff) :response "Why a symbol?"))))
  (should (equal "> In notes.txt, line 3:\n>\n> todo\n\nNo."
                 (harness-thread-text (list :refs '((:kind "buffer" :name "notes" :file "notes.txt" :line 3 :text "todo"))
                                            :response "No."))))
  (should (equal "> In a.el, line 7 (before the change):\n>\n> x\n\nWhy?"
                 (harness-thread-text (list :refs '((:kind "diff" :file "a.el" :side "old" :line 7 :text "x"))
                                            :response "Why?")))))

(ert-deftest harness-thread-quote-links-the-message-it-quotes ()
  "A quote of the chat names the message it is of, with the canonical link.
The model reads the message again by it, a message from before a compaction
too, and the agent's own words are no exception: the id of the node was in
the reference, but never reached the model.  The link names the session when
the reference does, else it is to a message of the session the reply is sent in."
  (let ((ref (append harness-thread-test--chat '(:session "s-1f2e"))))
    (should (equal "harness:session/s-1f2e/message/n-1" (harness-thread-ref-link ref)))
    (should (equal (list :kind 'message :session "s-1f2e" :message "n-1")
                   (harness-links-parse (harness-thread-ref-link ref))))
    (should (equal "Your earlier message (harness:session/s-1f2e/message/n-1):" (harness-thread-ref-header ref)))
    ;; In the text, quoted with the words: a reader that takes the quote
    ;; apart finds it whole.
    (should (equal (concat "> Your earlier message (harness:session/s-1f2e/message/n-1):\n>\n"
                           "> The build is green.\n\nGood.")
                   (harness-thread-text (list :refs (list ref) :response "Good.")))))
  (should (equal "harness:message/n-1" (harness-thread-ref-link harness-thread-test--chat)))
  ;; Whose words they are, the model's own or the user's.
  (dolist (case '(("agent" nil "Your earlier message") ("agent" "thinking" "Your earlier thinking")
                  ("plan" nil "Your earlier plan") ("thread" nil "Your earlier answer in a thread")
                  ("report" nil "Your earlier report") ("tool" "bash" "Your earlier call of bash")
                  ("tool" nil "Your earlier tool call") ("message" nil "An earlier message")
                  ("you" nil "My earlier message") ("user" nil "My earlier message")))
    (pcase-let ((`(,who ,label ,owner) case))
      (should (equal (format "%s (harness:message/n-9):" owner)
                     (harness-thread-ref-header
                      (append (list :kind "chat" :node "n-9" :who who :text "x")
                              (and label (list :label label))))))))
  ;; Nothing to link: a diff, a buffer, a reference that names no node.  The
  ;; header is what it was: nothing for the agent's words, the user's own message.
  (should-not (harness-thread-ref-link harness-thread-test--diff))
  (should-not (harness-thread-ref-link '(:kind "buffer" :name "notes" :node "n-1" :text "todo")))
  (should-not (harness-thread-ref-link '(:kind "chat" :who "agent" :text "x")))
  (should-not (harness-thread-ref-link '(:kind "chat" :node "" :who "agent" :text "x")))
  (should-not (harness-thread-ref-header '(:kind "chat" :who "agent" :text "x")))
  (should (equal "My earlier message:" (harness-thread-ref-header '(:kind "chat" :who "you" :text "x")))))

(ert-deftest harness-thread-makes-a-block-of-its-data ()
  "The block's text is the whole reply and its data is kept to draw it from;
the response can come with the data or after it.  Whatever a JSON array parsed
as is a list, and a key without a value is not kept."
  (let* ((block (harness-thread-block (list :refs (list harness-thread-test--chat) :id nil) "Good."))
         (data (plist-get block :thread)))
    (should (harness-thread-block-p block))
    (should (equal "text" (plist-get block :type)))
    (should (equal harness-thread-test--quoted-good (plist-get block :text)))
    (should (equal "Good." (harness-thread-response block)))
    (should (equal "Good." (plist-get data :response)))
    (should-not (plist-member data :id)))
  (should (equal "Good." (harness-thread-response
                          (harness-thread-block (list :refs (list harness-thread-test--chat) :response "Good.")))))
  ;; A vector of references, as some JSON gives, and one that is no reference.
  (let ((data (harness-thread-normalize (list :refs (vector harness-thread-test--chat "junk") :response "x"))))
    (should (equal (list harness-thread-test--chat) (plist-get data :refs))))
  (should-not (harness-thread-block-p '(:type "text" :text "words")))
  (should-not (harness-thread-block-p '(:type "image" :thread (:refs nil))))
  (should (equal "" (harness-thread-response '(:type "text" :text "words")))))

(ert-deftest harness-thread-text-of-blocks-keeps-the-quotes-on-their-own-lines ()
  "The text of a message with replies in threads has them after the words, a
paragraph apart, so a quote starts a line; a message of plain text is
unchanged and keeps no `:blocks'."
  (let ((reply (harness-thread-block (list :refs (list harness-thread-test--chat)) "Good.")))
    (should (equal (concat "Intro\n\n" harness-thread-test--quoted-good)
                   (harness-blocks-text (list (list :type "text" :text "Intro") reply))))
    (should (equal harness-thread-test--quoted-good (harness-blocks-text (list reply))))
    (should-not (harness-blocks-only-text-p (list reply)))
    (should (harness-blocks-only-text-p (list (list :type "text" :text "Intro"))))))

(ert-deftest harness-thread-attachments-are-blocks ()
  "A reply in the compose box is an attachment with the data and the response;
queued, it is the block of that reply when the queue goes out, and a queued
message shows as the node it will be."
  (let* ((att (list :label "reply 1" :response "Good." :thread (list :refs (list harness-thread-test--chat))))
         (blocks (harness-attachments-to-blocks (list att))))
    (should (equal (list (harness-thread-block (plist-get att :thread) "Good.")) blocks))
    (let ((node (harness-queued-message-node (list :id "q-1" :text "Intro" :attachments (list att)))))
      (should (equal (concat "Intro\n\n" harness-thread-test--quoted-good) (plist-get node :content)))
      (should (equal blocks (cl-remove-if-not #'harness-thread-block-p (plist-get node :blocks)))))))

(ert-deftest harness-thread-block-comes-over-acp ()
  "A text block with `_harness.thread' is a reply: the thread's data and the
response make the block, as the compose box's attachment does."
  (let* ((data (list :refs (list harness-thread-test--chat)))
         (block (harness-acp--block-from-acp
                 (list :type "text" :text "Good." :_harness (list :thread data)))))
    (should (equal (harness-thread-block data "Good.") block))
    (should (equal harness-thread-test--quoted-good (plist-get block :text))))
  ;; A plain text block is still one.
  (should (equal '(:type "text" :text "words") (harness-acp--block-from-acp '(:type "text" :text "words"))))
  ;; And it survives the JSON between the processes.
  (let* ((json (harness-json-encode
                (list :type "text" :text "Good."
                      :_harness (list :thread (list :refs (list harness-thread-test--chat harness-thread-test--diff))))))
         (parsed (harness-json-parse json))
         (block (harness-acp--block-from-acp parsed)))
    (should (= 2 (length (harness-thread-refs (plist-get block :thread)))))
    (should (equal "chat" (harness-thread-ref-kind (car (harness-thread-refs (plist-get block :thread))))))
    (should (equal 18 (plist-get (cadr (harness-thread-refs (plist-get block :thread))) :line)))))

(ert-deftest harness-thread-every-quote-is-a-headed-block-quote ()
  "A message of the chat, a review comment and a report quote the same way:
a line that says what it is and links it, then the words as a block quote.
What differs is what the header says, never how the quote is made."
  (dolist (ref (list harness-thread-test--chat
                     '(:kind "comment" :author "Noah" :file "a.el" :line 2
                       :task "t-1" :thread "t-2" :text "Why two?")
                     '(:kind "report" :who "report" :task "t-1" :text "# Done\n\nFixed.")))
    (ert-info ((format "%s" (harness-thread-ref-kind ref)))
      (let ((quote (harness-thread-quote (list :refs (list ref)))))
        (should (string-match-p "\\`> [^\n]+:\n>\n> " quote))))))

(provide 'harness-thread-test)
;;; harness-thread-test.el ends here

;;;; The <thread> form in messages

(defun harness-thread-test--tagged (text)
  "Return the parsed blocks of TEXT without the offsets and the raw text."
  (mapcar (lambda (block)
            (list :id (plist-get block :id) :status (plist-get block :status)
                  :quote (plist-get block :quote) :body (plist-get block :body)))
          (harness-thread-parse-blocks text)))

(ert-deftest harness-thread-parses-the-strict-tag-form ()
  "The <thread> form is read strictly: lowercase exact tags, id and
status in double quotes and nothing else in the opening tag, an optional
<quote> first, and the answer not wrapped in another tag.  The tags may
be on lines of their own or run into the text, and a block never closed,
one in code, and a tag a sentence mentions with no closing tag are no
replies."
  (should (equal '((:id "t-1" :status nil :quote "The build is green." :body "Why?"))
                 (harness-thread-test--tagged
                  "<thread id=\"t-1\">\n<quote>The build is green.</quote>\nWhy?\n</thread>")))
  (should (equal '((:id "t-2" :status nil :quote "Q" :body "A"))
                 (harness-thread-test--tagged
                  "<thread id=\"t-2\"><quote>Q</quote>A</thread>")))
  ;; Attributes in either order, status closing the thread, and no id
  ;; for a new thread.
  (should (equal '((:id "t-3" :status "closed" :quote "Q" :body "A"))
                 (harness-thread-test--tagged
                  "<thread status=\"closed\" id=\"t-3\"><quote>Q</quote>A</thread>")))
  (should (equal '((:id nil :status nil :quote "Q" :body "A"))
                 (harness-thread-test--tagged
                  "<thread><quote>Q</quote>A</thread>")))
  ;; The quote is optional, and so is the answer when there is one.
  (should (equal '((:id "t-4" :status nil :quote nil :body "A line."))
                 (harness-thread-test--tagged "<thread id=\"t-4\">A line.</thread>")))
  (should (equal '((:id "t-5" :status "closed" :quote "Q" :body nil))
                 (harness-thread-test--tagged
                  "<thread id=\"t-5\" status=\"closed\"><quote>Q</quote></thread>")))
  ;; The forms the old parser took are malformed now.
  (dolist (text (list "<thread id=t-1>A</thread>"
                      "<thread id='t-1'>A</thread>"
                      "<Thread id=\"t-1\">A</Thread>"
                      "<thread><id>t-5</id><quote>Q</quote>A</thread>"
                      "<thread id=\"t-6\">\n<quote >Q</quote >\n<reply>A</reply>\n</thread>"
                      "<thread  id=\"t-7\">A</thread>"
                      "<thread id=\"t-8\" other=\"x\">A</thread>"
                      "<thread id=\"t-9\" status=\"maybe\">A</thread>"))
    (should-not (harness-thread-parse-blocks text)))
  ;; Never closed, and a code example, are no replies; nor is a tag a
  ;; sentence mentions without closing it.
  (should-not (harness-thread-parse-blocks "<thread id=\"t-8\">\nA question?"))
  (should-not (harness-thread-parse-blocks "Write a <thread id=\"t-9\"> block."))
  (should-not (harness-thread-parse-blocks
               "As in:\n\n```\n<thread id=\"t-9\"><quote>Q</quote>A</thread>\n```\n"))
  (should-not (harness-thread-parse-blocks
               "Inline ` <thread id=\"t-9\"><quote>Q</quote>A </thread> ` too."))
  ;; Two blocks, in order, with the text between them left alone.
  (should (equal '((:id "t-10" :status nil :quote nil :body "One.")
                   (:id "t-11" :status nil :quote nil :body "Two."))
                 (harness-thread-test--tagged
                  "<thread id=\"t-10\">One.</thread>\nAnd in between.\n<thread id=\"t-11\">Two.</thread>")))
  ;; An attempt never closed does not swallow the strict block after it.
  (should (equal '((:id "t-12" :status nil :quote nil :body "Good."))
                 (harness-thread-test--tagged
                  "<thread id=t-broken>\ntext that never closes\n<thread id=\"t-12\">Good.</thread>"))))

(ert-deftest harness-thread-finds-the-malformed-attempts ()
  "`harness-thread-find-malformed' says what keeps a block from being a
strict reply: the tag's case, the attributes, the quote's tags, a
wrapper around the answer, a missing closing tag, or a closing tag
alone.  A strict block and code are no problems, and a tag mentioned in
a sentence with no close is none either."
  (let ((found (harness-thread-find-malformed "<thread id=t-1>A</thread>")))
    (should (= 1 (length found)))
    (should (string-match-p "double quotes" (string-join (plist-get (car found) :problems) " "))))
  (let ((found (harness-thread-find-malformed "<Thread id=\"t-1\">A</Thread>")))
    (should (string-match-p "lowercase" (string-join (plist-get (car found) :problems) " "))))
  (let ((found (harness-thread-find-malformed
                "<thread id=\"t-1\">\n<quote>Q</quote><reply>A</reply>\n</thread>")))
    (should (string-match-p "wrapped" (string-join (plist-get (car found) :problems) " "))))
  (let ((found (harness-thread-find-malformed "<thread id=\"t-1\">\nA\n")))
    (should (plist-get (car found) :unclosed))
    (should (string-match-p "never closed" (string-join (plist-get (car found) :problems) " "))))
  (let ((found (harness-thread-find-malformed "A stray </thread> here.")))
    (should (= 1 (length found)))
    (should (string-match-p "no opening" (string-join (plist-get (car found) :problems) " "))))
  ;; A strict block that copies the format's placeholder names no thread.
  (let ((found (harness-thread-find-malformed
                "<thread id=\"THREAD_ID\">\n<quote>Q</quote>\nA\n</thread>")))
    (should (= 1 (length found)))
    (should (string-match-p "placeholder"
                            (string-join (plist-get (car found) :problems) " "))))
  ;; An attempt never closed is one problem, and the block after it stays.
  (let ((found (harness-thread-find-malformed
                "<thread id=t-broken>\ntext\n<thread id=\"t-12\">Good.</thread>")))
    (should (= 1 (length found)))
    (should (plist-get (car found) :unclosed)))
  ;; Strict blocks, fenced examples and a sentence's mention are quiet.
  (should-not (harness-thread-find-malformed
               "<thread id=\"t-1\">\n<quote>Q</quote>\nA\n</thread>"))
  (should-not (harness-thread-find-malformed
               "As in:\n\n```\n<thread id=t-1><quote>Q</quote>A</thread>\n```\n"))
  (should-not (harness-thread-find-malformed "Write a <thread id=\"t-1\"> block."))
  (should-not (harness-thread-find-malformed "Inline ` <thread id=t-1>A</thread> ` here.")))

(ert-deftest harness-thread-renders-a-tag-block-as-a-mail-quotes-it ()
  "The text kept of a parsed block is its quote as a block quote, then the answer."
  (let ((block (car (harness-thread-parse-blocks
                     "<thread id=\"t-1\">\n<quote>The build is green.\nThe deploy is pending.</quote>\nWhy?\n</thread>"))))
    (should (equal "> The build is green.\n> The deploy is pending.\n\nWhy?"
                   (harness-thread-render-text block)))))
