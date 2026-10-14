;;; harness-tools-question-test.el --- Tests for the ask_user tool and question/ask  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo--delay)
(defvar harness-tools-question--questions)
(declare-function harness-tools-question--answer-blocks "harness-tools-question" (answer))
(declare-function harness-tools-question--answer-without-blocks "harness-tools-question" (answer))

(defmacro harness-tools-question-test-with (&rest body)
  "Load the state layer with the demo provider and ask_user, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent tools-question))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-tools-question--questions)
     (let ((harness-provider-demo--delay 0.005)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defun harness-tools-question-test-session ()
  "Create a demo session and return its id."
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id))

(defun harness-tools-question-test-run (sid name input &optional call-id)
  "Execute tool NAME with INPUT in SID; return the promise.
CALL-ID, when given, is the call's id: the one a call node the session
recorded for it carries.  Otherwise the call gets a fresh one."
  (harness-call 'tools/execute sid (list :id (or call-id (harness-short-id)) :name name :input input)))

(ert-deftest harness-tools-question-registers-ask-user ()
  (harness-tools-question-test-with
    (should (eq 'meta (plist-get (harness-call 'tools/get "ask_user") :kind)))))

(ert-deftest harness-tools-question-ask-user-blocks-and-answers ()
  (harness-tools-question-test-with
    (let* ((sid (harness-tools-question-test-session))
           (asked nil)
           (p (progn
                (harness-on 'question/asked (lambda (s item) (push (cons s item) asked)))
                (harness-tools-question-test-run sid "ask_user"
                                              '(:question "Which colour?" :options ("red" "green"))))))
      (harness-test-wait (lambda () (harness-call 'question/pending sid)) 5 "pending question")
      (should-not (harness-promise-settled-p p))
      (let* ((pending (harness-call 'question/pending sid))
             (item (car pending))
             (payload (plist-get item :payload)))
        (should (= 1 (length pending)))
        (should (eq 'question (plist-get item :kind)))
        (should (equal "Which colour?" (plist-get payload :question)))
        (should (equal '("red" "green") (plist-get payload :options)))
        (should (plist-get payload :call-id))
        (should (eq 'blocked (plist-get (harness-call 'session/get sid) :status)))
        (should (= 1 (length asked)))
        (should (equal sid (caar asked)))
        (should (equal (plist-get item :id) (plist-get (cdar asked) :id)))
        (should (harness-call 'question/answer sid (plist-get item :id) '(:answer "green"))))
      (let ((result (harness-test-await p)))
        (should (equal "green" (plist-get result :content)))
        (should-not (plist-get result :is-error)))
      (should (null (harness-call 'session/pending sid)))
      (should (eq 'idle (plist-get (harness-call 'session/get sid) :status))))))

(defun harness-tools-question-test-asked (sid input)
  "Ask INPUT in SID; return the pending question's payload once it waits."
  (harness-tools-question-test-run sid "ask_user" input)
  (harness-test-wait (lambda () (harness-call 'question/pending sid)) 5 "pending question")
  (plist-get (car (harness-call 'question/pending sid)) :payload))

(ert-deftest harness-tools-question-ask-user-options-with-diagrams ()
  "Options may each carry an ASCII diagram or an image; the question keeps
the labels as its options and the diagrams beside them, one per option."
  (harness-tools-question-test-with
    (let* ((sid (harness-tools-question-test-session))
           (cwd (plist-get (harness-call 'session/get sid) :cwd)))
      (make-directory (expand-file-name "img" cwd) t)
      (write-region "not really a png" nil (expand-file-name "img/top.png" cwd) nil 'silent)
      (let ((payload (harness-tools-question-test-asked
                      sid `(:question "Which layout?"
                            :options ((:label "Sidebar" :diagram "\n```text\n+--+----+\n|  |    |\n+--+----+\n```\n")
                                      (:label "Tabs" :image "img/top.png"))))))
        (should (equal '("Sidebar" "Tabs") (plist-get payload :options)))
        (should (equal `((:type "ascii" :text "+--+----+\n|  |    |\n+--+----+")
                         (:type "image" :path ,(expand-file-name "img/top.png" cwd) :mime "image/png"))
                       (plist-get payload :diagrams)))
        (let ((pid (plist-get (car (harness-call 'question/pending sid)) :id)))
          ;; The answer is the label.
          (should (harness-call 'question/answer sid pid "Tabs"))))
      ;; Without diagrams nothing changes: no `:diagrams', strings as they were.
      (let ((payload (harness-tools-question-test-asked
                      sid '(:question "Which colour?" :options ("red" (:label "green") 7)))))
        (should (equal '("red" "green") (plist-get payload :options)))
        (should-not (plist-member payload :diagrams))))))

(ert-deftest harness-tools-question-ask-user-diagrams-all-or-none ()
  "A call where only some options have a diagram, or with a malformed
option, is an error saying what to fix, and asks nothing."
  (harness-tools-question-test-with
    (let* ((sid (harness-tools-question-test-session))
           (cwd (plist-get (harness-call 'session/get sid) :cwd))
           (try (lambda (options)
                  (let ((result (harness-test-await
                                 (harness-tools-question-test-run sid "ask_user"
                                                               (list :question "Which?" :options options)))))
                    (should (plist-get result :is-error))
                    (should-not (harness-call 'question/pending sid))
                    (plist-get result :content)))))
      (write-region "x" nil (expand-file-name "notes.txt" cwd) nil 'silent)
      (should (string-match-p "Every option needs a diagram once one has: options 2 and 3 have none"
                              (funcall try '((:label "A" :diagram "[A]") "B" (:label "C")))))
      (should (string-match-p "option 1 has none"
                              (funcall try '("A" (:label "B" :diagram "[B]")))))
      ;; A blank diagram is none.
      (should (string-match-p "option 2 has none"
                              (funcall try '((:label "A" :diagram "[A]") (:label "B" :diagram " \n ")))))
      (should (string-match-p "Option 1 has both a diagram and an image"
                              (funcall try '((:label "A" :diagram "[A]" :image "a.png")))))
      (should (string-match-p "Option 2 needs a label"
                              (funcall try '((:label "A" :diagram "[A]") (:diagram "[B]")))))
      (should (string-match-p "Option 1: image missing.png not found"
                              (funcall try '((:label "A" :image "missing.png") (:label "B" :diagram "[B]")))))
      (should (string-match-p "Option 1: notes.txt is not an image file"
                              (funcall try '((:label "A" :image "notes.txt") (:label "B" :diagram "[B]")))))
      ;; A full page's screenshot, 1400x12000: too large to show; crop it.
      (let ((coding-system-for-write 'no-conversion))
        (write-region (unibyte-string #x89 ?P ?N ?G ?\r ?\n #x1a ?\n 0 0 0 13 ?I ?H ?D ?R
                                      0 0 5 120 0 0 46 224 8 6 0 0 0)
                      nil (expand-file-name "page.png" cwd) nil 'silent))
      (should (string-match-p "Option 2: image page.png is 1400x12000 pixels, too large to show; crop it"
                              (funcall try '((:label "A" :diagram "[A]") (:label "B" :image "page.png")))))
      (should (eq 'idle (plist-get (harness-call 'session/get sid) :status))))))

(defvar harness-tools-question-image-max-bytes)

(ert-deftest harness-tools-question-image-gives-the-file ()
  "`question/image' gives an option's image, read where the harness runs,
for a client that cannot read the path; it says why when it cannot."
  (harness-tools-question-test-with
    (let* ((sid (harness-tools-question-test-session))
           (cwd (plist-get (harness-call 'session/get sid) :cwd))
           (bytes harness-test-png))
      (let ((coding-system-for-write 'no-conversion))
        (write-region bytes nil (expand-file-name "a.png" cwd) nil 'silent)
        (write-region "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"/>" nil
                      (expand-file-name "b.svg" cwd) nil 'silent))
      (harness-tools-question-test-asked sid '(:question "Which?" :options ((:label "A" :image "a.png")
                                                                         (:label "B" :image "b.svg"))))
      (let ((pid (plist-get (car (harness-call 'question/pending sid)) :id)))
        (let ((image (harness-call 'question/image sid pid 0)))
          (should (equal "image/png" (plist-get image :mime)))
          (should (equal bytes (base64-decode-string (plist-get image :data)))))
        (should (equal "image/svg+xml" (plist-get (harness-call 'question/image sid pid 1) :mime)))
        (should (string-match-p "Option 2 of question .* shows no image"
                                (cadr (should-error (harness-call 'question/image sid pid 2)))))
        (should (string-match-p "No question nope waits"
                                (cadr (should-error (harness-call 'question/image sid "nope" 0)))))
        (let ((harness-tools-question-image-max-bytes 8))
          (should (string-match-p "a\\.png is larger than 8"
                                  (cadr (should-error (harness-call 'question/image sid pid 0))))))
        (delete-file (expand-file-name "a.png" cwd))
        (should (string-match-p "a\\.png cannot be read any more"
                                (cadr (should-error (harness-call 'question/image sid pid 0)))))
        ;; Over ACP too, by the names a client gives.
        (harness-test-load-module 'acp)
        (should (equal "image/svg+xml"
                       (plist-get (harness-acp--call-extension "question/image"
                                                               (list :sessionId sid :pid pid :index 1))
                                  :mime)))
        ;; Once answered, it is no longer given.
        (harness-call 'question/answer sid pid "A")
        (should-error (harness-call 'question/image sid pid 1))))))

(ert-deftest harness-tools-question-demo-images-script ()
  "The demo provider's `images' script draws SVG mockups in the session's
temporary directory and asks with one per option, as a model is told to."
  (harness-tools-question-test-with
    (let* ((sid (harness-tools-question-test-session))
           (tmp (harness-call 'session/tmp-dir sid))
           (p (harness-call 'agent/prompt sid "Show me the layouts as images")))
      (harness-test-wait (lambda () (harness-call 'question/pending sid)) 5 "the question with images")
      (let* ((item (car (harness-call 'question/pending sid)))
             (payload (plist-get item :payload))
             (diagrams (plist-get payload :diagrams)))
        (should (equal '("Sidebar on the left" "Sidebar on the right" "Tabs across the top")
                       (plist-get payload :options)))
        (should (= 3 (length diagrams)))
        (dolist (d diagrams)
          (should (equal "image" (plist-get d :type)))
          (should (equal "image/svg+xml" (plist-get d :mime)))
          (should (file-in-directory-p (plist-get d :path) tmp))
          (with-temp-buffer
            (insert-file-contents (plist-get d :path))
            (should (looking-at-p "<svg [^>]*viewBox=\"0 0 600 400\""))))
        ;; Three drawings, not one thrice.
        (should (= 3 (length (delete-dups (mapcar (lambda (d) (with-temp-buffer
                                                                (insert-file-contents (plist-get d :path))
                                                                (buffer-string)))
                                                  diagrams)))))
        (harness-call 'question/answer sid (plist-get item :id) "Tabs across the top"))
      (should (eq 'end-turn (plist-get (harness-test-await p) :stop-reason))))))

(ert-deftest harness-tools-question-ask-user-string-answer-and-cancel ()
  (harness-tools-question-test-with
    (let* ((sid (harness-tools-question-test-session))
           (p1 (harness-tools-question-test-run sid "ask_user" '(:question "One?")))
           (p2 (harness-tools-question-test-run sid "ask_user" '(:question "Two?"))))
      (harness-test-wait (lambda () (= 2 (length (harness-call 'question/pending sid)))) 5 "two questions")
      (let ((ids (mapcar (lambda (it) (plist-get it :id)) (harness-call 'question/pending sid))))
        (should (harness-call 'question/answer sid (car ids) "yes please"))
        (should (equal "yes please" (plist-get (harness-test-await p1) :content)))
        (should (harness-call 'question/cancel sid (cadr ids)))
        (should (equal "The user dismissed the question" (plist-get (harness-test-await p2) :content)))
        ;; Answering again is a no-op.
        (should-not (harness-call 'question/answer sid (car ids) "again")))
      (should (eq 'idle (plist-get (harness-call 'session/get sid) :status))))))

(ert-deftest harness-tools-question-ask-for-the-harness ()
  "`question/ask' asks the user a question with no tool call behind it:
the session is blocked on it, its payload carries what the caller adds,
and the caller hears the answer, or that it was dismissed."
  (harness-tools-question-test-with
    (let* ((sid (harness-tools-question-test-session))
           (heard nil)
           (asked nil)
           (pid (progn
                  (harness-on 'question/asked (lambda (s item) (push (cons s (plist-get item :id)) asked)))
                  (harness-call 'question/ask sid
                                '(:question "Which way?" :options ["Left" "Right"] :extra (:a 1))
                                (lambda (text dismissed) (push (list text dismissed) heard))))))
      (should (equal (list (cons sid pid)) asked))
      (should (eq 'blocked (plist-get (harness-call 'session/get sid) :status)))
      (let ((payload (plist-get (car (harness-call 'question/pending sid)) :payload)))
        (should (equal "Which way?" (plist-get payload :question)))
        (should (equal '("Left" "Right") (plist-get payload :options)))
        (should (eq t (plist-get payload :allow-free-text)))
        (should (equal '(:a 1) (plist-get payload :extra)))
        (should-not (plist-get payload :call-id)))
      (should (harness-call 'question/answer sid pid '(:answer "Right")))
      (should (equal '(("Right" nil)) heard))
      (should-not (harness-call 'question/pending sid))
      (should (eq 'idle (plist-get (harness-call 'session/get sid) :status)))
      ;; Asked again, then dismissed; free text off.
      (let ((pid (harness-call 'question/ask sid '(:question "Sure?" :allow-free-text nil)
                               (lambda (text dismissed) (push (list text dismissed) heard)))))
        (should-not (plist-get (plist-get (car (harness-call 'question/pending sid)) :payload) :allow-free-text))
        (should (harness-call 'question/cancel sid pid))
        (should (equal '("The user dismissed the question" t) (car heard)))
        (should-not (harness-call 'question/answer sid pid "late"))
        (should (= 2 (length heard)))))))

(ert-deftest harness-tools-question-ask-user-inside-a-turn ()
  "The demo `ask' script calls ask_user; the turn blocks until the UI answers."
  (harness-tools-question-test-with
    (let* ((sid (harness-tools-question-test-session))
           (p (harness-call 'agent/prompt sid "ask me")))
      (harness-test-wait (lambda () (harness-call 'question/pending sid)) 5 "question during turn")
      (should (eq 'blocked (plist-get (harness-call 'session/get sid) :status)))
      (let ((pid (plist-get (car (harness-call 'question/pending sid)) :id)))
        (harness-call 'question/answer sid pid "blue"))
      (should (eq 'end-turn (plist-get (harness-test-await p) :stop-reason)))
      (let ((result (cl-find-if (lambda (n) (eq (plist-get n :kind) 'tool-result)) (harness-call 'session/nodes sid))))
        (should (equal "blue" (plist-get result :output))))
      (should (eq 'idle (plist-get (harness-call 'session/get sid) :status))))))


(ert-deftest harness-tools-question-answer-attachments-reach-the-model ()
  "The files attached to an answer reach the model with it.
The answer's text, naming the screenshot by its token, is the ask_user
result; the screenshot goes as a message of the user's that the turn
takes with that result, so the next request carries it right after the
result, its token before it, as a message sent first would.  The
pending list and the event every client hears keep the text, never the
screenshot's bytes."
  (harness-tools-question-test-with
    (let* ((sid (harness-tools-question-test-session))
           (data (base64-encode-string harness-test-png t))
           (requests nil)
           (heard nil))
      (harness-on 'question/answered (lambda (_s _pid answer) (push answer heard)))
      (harness-on 'session/pending-resolved (lambda (_s _item answer) (push answer heard)))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (let ((p (harness-call 'agent/prompt sid "ask me")))
          (harness-test-wait (lambda () (harness-call 'question/pending sid)) 5 "question during turn")
          (let ((pid (plist-get (car (harness-call 'question/pending sid)) :id)))
            (should (harness-call 'question/answer sid pid
                                  (list :answer "like [image 1]"
                                        :blocks (list (list :type "image" :mime "image/png" :data data
                                                            :label "image 1"))))))
          (should (eq 'end-turn (plist-get (harness-test-await p) :stop-reason)))))
      (should (equal '((:answer "like [image 1]") (:answer "like [image 1]")) heard))
      (let* ((nodes (harness-call 'session/nodes sid))
             (result (cl-find-if (lambda (n) (eq (plist-get n :kind) 'tool-result)) nodes))
             (steering (cl-find-if (lambda (n) (plist-get (plist-get n :meta) :steering)) nodes)))
        (should (equal "like [image 1]" (plist-get result :output)))
        ;; The image's message, delivered with the answer.
        (should (equal "[image 1]" (plist-get steering :content)))
        (should (equal (plist-get result :id) (plist-get (plist-get steering :meta) :delivered-after)))
        (should (equal (list (list :type "image" :mime "image/png" :data data :label "image 1"))
                       (plist-get steering :blocks))))
      ;; The request after the answer: the result, then the image.
      (let ((content (plist-get (car (last (plist-get (car requests) :messages))) :content)))
        (should (equal '("tool_result" "text" "image") (mapcar (lambda (b) (plist-get b :type)) content)))
        (should (equal "like [image 1]" (plist-get (nth 0 content) :content)))
        (should (equal "[image 1]" (plist-get (nth 1 content) :text)))
        (should (equal data (plist-get (nth 2 content) :data)))))))

(ert-deftest harness-tools-question-answer-without-attachments-sends-no-message ()
  "Only an ask_user call a turn waits on sends the files of its answer.
An answer of text alone, or whose blocks are none, is only the answer;
so is one to a call no turn runs, which a message would start a turn
for, and one to a question the harness asked, which takes the text."
  (harness-tools-question-test-with
    (let ((sid (harness-tools-question-test-session))
          (image '(:type "image" :mime "image/png" :data "iVBO" :label "image 1"))
          (prompts nil)
          (heard nil))
      (should-not (harness-tools-question--answer-blocks "green"))
      (should-not (harness-tools-question--answer-blocks '(:answer "green")))
      (should-not (harness-tools-question--answer-blocks '(:answer "green" :blocks nil)))
      (should-not (harness-tools-question--answer-blocks '(:answer "green" :blocks ("junk" (:mime "image/png")))))
      (should (equal (list image) (harness-tools-question--answer-blocks (list :answer "x" :blocks (list 7 image)))))
      (should (equal '(:answer "x") (harness-tools-question--answer-without-blocks (list :answer "x" :blocks (list image)))))
      (should (equal "x" (harness-tools-question--answer-without-blocks "x")))
      (cl-letf* ((orig (symbol-function 'harness-method/agent/prompt))
                 ((symbol-function 'harness-method/agent/prompt)
                  (lambda (&rest args) (push args prompts) (apply orig args))))
        ;; In a turn, an answer whose blocks are none.
        (let ((p (harness-call 'agent/prompt sid "ask me")))
          (harness-test-wait (lambda () (harness-call 'question/pending sid)) 5 "question during turn")
          (should (harness-call 'question/answer sid (plist-get (car (harness-call 'question/pending sid)) :id)
                                '(:answer "green" :blocks ("junk" (:mime "image/png")))))
          (should (eq 'end-turn (plist-get (harness-test-await p) :stop-reason))))
        (should (= 1 (length prompts)))
        (should-not (cl-find-if (lambda (n) (plist-get (plist-get n :meta) :steering))
                                (harness-call 'session/nodes sid)))
        ;; A call no turn runs.
        (let ((p (harness-tools-question-test-run sid "ask_user" '(:question "Which colour?"))))
          (harness-test-wait (lambda () (harness-call 'question/pending sid)) 5 "pending question")
          (should (harness-call 'question/answer sid (plist-get (car (harness-call 'question/pending sid)) :id)
                                (list :answer "green" :blocks (list image))))
          (should (equal "green" (plist-get (harness-test-await p) :content))))
        ;; The harness's own question.
        (let ((pid (harness-call 'question/ask sid '(:question "Which way?")
                                 (lambda (text _dismissed) (push text heard)))))
          (should (harness-call 'question/answer sid pid (list :answer "left" :blocks (list image))))
          (should (equal '("left") heard))))
      (should (= 1 (length prompts))))))

(provide 'harness-tools-question-test)
;;; harness-tools-question-test.el ends here
