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

(defconst harness-thread-test--diff
  '(:kind "diff" :file "lisp/a.el" :side "new" :line 18 :end 19 :revision "0123456789abcdef"
    :text "(setq a18 'eighteen)\n(setq a19 19)")
  "A reference to two lines of a diff.")

(ert-deftest harness-thread-quotes-the-references-the-way-a-mail-does ()
  "The text of a reply is the quote of each reference, with a header for
what is not the agent's own words, a blank line between two, the response, and
the thread's marker once the thread is a comment in a review."
  (let ((data (list :refs (list harness-thread-test--chat) :response "Good.")))
    (should (equal "> The build is green.\n\nGood." (harness-thread-text data)))
    (should (equal "> The build is green.\n\nGood.\n\n[thread t-1a2b: answer with review_comment]"
                   (harness-thread-text (append data (list :id "t-1a2b"))))))
  ;; Several references: a quote each, and a multi-line quote line by line.
  (should (equal "> One.\n>\n> More.\n\n> Two.\n\nAll good."
                 (harness-thread-text
                  (list :refs (list '(:kind "chat" :node "n-1" :who "agent" :text "One.\n\nMore.")
                                    '(:kind "chat" :node "n-2" :who "agent" :text "Two."))
                        :response "All good."))))
  ;; The user's own message, a diff and a buffer say where they are from.
  (should (equal "> My earlier message:\n>\n> Check it.\n\nDone."
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

(ert-deftest harness-thread-makes-a-block-of-its-data ()
  "The block's text is the whole reply and its data is kept to draw it from;
the response can come with the data or after it.  Whatever a JSON array parsed
as is a list, and a key without a value is not kept."
  (let* ((block (harness-thread-block (list :refs (list harness-thread-test--chat) :id nil) "Good."))
         (data (plist-get block :thread)))
    (should (harness-thread-block-p block))
    (should (equal "text" (plist-get block :type)))
    (should (equal "> The build is green.\n\nGood." (plist-get block :text)))
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
    (should (equal "Intro\n\n> The build is green.\n\nGood."
                   (harness-blocks-text (list (list :type "text" :text "Intro") reply))))
    (should (equal "> The build is green.\n\nGood." (harness-blocks-text (list reply))))
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
      (should (equal "Intro\n\n> The build is green.\n\nGood." (plist-get node :content)))
      (should (equal blocks (cl-remove-if-not #'harness-thread-block-p (plist-get node :blocks)))))))

(ert-deftest harness-thread-block-comes-over-acp ()
  "A text block with `_harness.thread' is a reply: the thread's data and the
response make the block, as the compose box's attachment does."
  (let* ((data (list :refs (list harness-thread-test--chat)))
         (block (harness-acp--block-from-acp
                 (list :type "text" :text "Good." :_harness (list :thread data)))))
    (should (equal (harness-thread-block data "Good.") block))
    (should (equal "> The build is green.\n\nGood." (plist-get block :text))))
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

(provide 'harness-thread-test)
;;; harness-thread-test.el ends here

;;;; The <thread> form in messages

(defun harness-thread-test--tagged (text)
  "Return the parsed blocks of TEXT without the offsets and the raw text."
  (mapcar (lambda (block)
            (list :id (plist-get block :id) :status (plist-get block :status)
                  :quote (plist-get block :quote) :body (plist-get block :body)))
          (harness-thread-parse-blocks text)))

(ert-deftest harness-thread-parses-the-tag-forms-agents-write ()
  "The <thread> form is read as an agent writes it: tags on lines of their own
or one line, names in any case, the id quoted either way or bare, the quote
optional and wrapped in <quote>, the answer wrapped in <reply> or another tag,
the id a child tag, and the status a tag attribute.  A block never closed, or
one in a fenced code block, is no reply."
  (should (equal '((:id "t-1" :status nil :quote "The build is green." :body "Why?"))
                 (harness-thread-test--tagged
                  "<thread id=\"t-1\">\n<quote>The build is green.</quote>\nWhy?\n</thread>")))
  (should (equal '((:id "t-2" :status nil :quote "Q" :body "A"))
                 (harness-thread-test--tagged
                  "<thread id=\"t-2\"><quote>Q</quote>A</thread>")))
  (should (equal '((:id "t-3" :status "closed" :quote "Q" :body "A"))
                 (harness-thread-test--tagged
                  "<Thread id='t-3' status=\"closed\"><QUOTE>Q</QUOTE><reply>A</reply></Thread>")))
  (should (equal '((:id "t-4" :status nil :quote nil :body "A line."))
                 (harness-thread-test--tagged "<thread id=t-4>A line.</thread>")))
  (should (equal '((:id "t-5" :status nil :quote "Q" :body "A"))
                 (harness-thread-test--tagged
                  "<thread><id>t-5</id><quote>Q</quote>A</thread>")))
  ;; Whitespace inside the tag: the quote's tags still leave the words alone.
  (should (equal '((:id "t-6" :status nil :quote "Q" :body "A"))
                 (harness-thread-test--tagged
                  "<thread id=\"t-6\">\n<quote >Q</quote >\n<reply>A</reply>\n</thread>")))
  ;; No quote: the answer is the whole block.
  (should (equal '((:id "t-7" :status nil :quote nil :body "Just this."))
                 (harness-thread-test--tagged "<thread id=\"t-7\">Just this.</thread>")))
  ;; Never closed, and a code example, are no replies.
  (should-not (harness-thread-parse-blocks "<thread id=\"t-8\">\nA question?"))
  (should-not (harness-thread-parse-blocks
               "As in:\n\n```\n<thread id=\"t-9\"><quote>Q</quote>A</thread>\n```\n"))
  ;; Two blocks, in order, with the text between them left alone.
  (should (equal '((:id "t-10" :status nil :quote nil :body "One.")
                   (:id "t-11" :status nil :quote nil :body "Two."))
                 (harness-thread-test--tagged
                  "<thread id=\"t-10\">One.</thread>\nAnd in between.\n<thread id=\"t-11\">Two.</thread>"))))

(ert-deftest harness-thread-renders-a-tag-block-as-a-mail-quotes-it ()
  "The text kept of a parsed block is its quote as a block quote, then the answer."
  (let ((block (car (harness-thread-parse-blocks
                     "<thread id=\"t-1\">\n<quote>The build is green.\nThe deploy is pending.</quote>\nWhy?\n</thread>"))))
    (should (equal "> The build is green.\n> The deploy is pending.\n\nWhy?"
                   (harness-thread-render-text block)))))
