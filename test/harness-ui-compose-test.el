;;; harness-ui-compose-test.el --- Tests for the compose box's attachments  -*- lexical-binding: t; -*-

;;; Commentary:

;; The compose box in a host of its own (a read-only line, the chips,
;; the box): links dropped on it download in the background behind a
;; chip with their progress, web pages go in as text, data: links and
;; dropped text land in the box, images and videos show thumbnails, and
;; yanking takes images and copied files off the clipboard into the
;; media ring, and C-c C-v is no longer the box's, so a chat's [Verify]
;; keeps it.  Typing outside the box goes into it (the keys go through
;; the real command loop), except the keys that are commands where they
;; are typed.  C-c . presses a key on a panel above the box from the
;; box -- the nearest panel that binds it, or the Nth up with a numeric
;; argument -- and puts point back in the box; M-< and M-> stay in the
;; box, going on to the buffer's edges from the box's own.  Every
;; attachment has a token in the text -- an image [image 1], a file its
;; @ reference, a task @task:ID -- shown as the same chip, which opens
;; it; deleting the token detaches it.  The clipboard and the display
;; are stubbed; downloads go to a web server in this Emacs.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-media-ring)
(defvar harness-media-ring--loaded)
(defvar harness-media-ring-max)
(defvar compose-quote-inline-hint)
(defvar-local harness-ui-compose-test--draws 0 "How many times the test host drew.")
(defvar-local harness-ui-compose-test--accent nil
  "The face of the bar down the test host's box (`harness-compose-insert' :accent), or nil.")
(defvar-local harness-ui-compose-test--panels nil
  "The panels the test host draws under its line: (NAME TEXT KEYMAP) each.
The first is the farthest from the box.  The text carries the name as
its `harness-compose-panel' and the keymap as its `keymap'.")

(defun harness-ui-compose-test--draw ()
  "Draw the test host: a read-only line, its panels, the attachment chips and the box.
With undo off, as the hosts draw."
  (cl-incf harness-ui-compose-test--draws)
  (harness-compose-capture)
  (let ((inhibit-read-only t)
        (buffer-undo-list t)
        (offset (and (harness-compose-in-p) (- (point) harness-compose-start))))
    (erase-buffer)
    (insert (propertize "The transcript.\n" 'read-only t))
    (pcase-dolist (`(,name ,text ,keymap) harness-ui-compose-test--panels)
      (insert (propertize text 'harness-compose-panel name 'keymap keymap 'read-only t)))
    (let ((start (point)))
      (harness-compose-insert-attachments)
      (put-text-property start (point) 'read-only t))
    (harness-compose-insert nil nil :accent harness-ui-compose-test--accent)
    (when offset (goto-char (min (+ harness-compose-start offset) harness-compose-end)))))

(defmacro harness-ui-compose-test-with (&rest body)
  "Run BODY in a buffer hosting a compose box, shown in the selected window.
`dir' is the project and the state directory.  The echo area is not
told which keys answer a quote inline (`compose-quote-inline-hint'),
which batch Emacs would print."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp-server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent acp ui ui-media ui-compose))
         (harness-test-load-module m)))
     (setq harness-media-ring nil harness-media-ring--loaded nil)
     (let ((harness-acp-token nil)
           (compose-quote-inline-hint nil)
           (default-directory dir)
           (buf (generate-new-buffer "*compose test*")))
       (unwind-protect
           (save-window-excursion
             (set-window-buffer (selected-window) buf)
             (with-current-buffer buf
               (use-local-map (make-composed-keymap nil harness-compose-map))
               (harness-compose-setup :project (lambda () dir) :redraw #'harness-ui-compose-test--draw)
               (harness-ui-compose-test--draw)
               ,@body))
         (when (buffer-live-p buf) (kill-buffer buf))
         (setq harness-media-ring nil harness-media-ring--loaded nil)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defmacro harness-ui-compose-test-messages (&rest body)
  "Run BODY and return the messages it showed, oldest first."
  (declare (indent 0))
  `(let ((messages nil))
     (cl-letf (((symbol-function 'message)
                (lambda (format &rest args)
                  (when format (push (apply #'format-message format args) messages)))))
       ,@body)
     (nreverse messages)))

(defun harness-ui-compose-test--bytes (file)
  "Return the bytes of FILE."
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string)))

(defun harness-ui-compose-test--pending ()
  "Return the first pending download of the box, or nil."
  (cl-find-if (lambda (a) (plist-get a :pending)) harness-compose-attachments))

(defun harness-ui-compose-test--settled ()
  "Non-nil once no download of the box is pending."
  (not (harness-ui-compose-test--pending)))


;;;; Replies in threads

(defconst harness-ui-compose-test--ref
  '(:kind "chat" :node "n-1" :who "agent" :text "The build is green.\nThe deploy is pending.")
  "A reference to part of a message of the agent's.")

(defun harness-ui-compose-test--cards ()
  "Return the overlays of the box that show a reply in a thread as a card."
  (cl-remove-if-not (lambda (ov) (plist-get (overlay-get ov 'harness-compose-attachment) :thread))
                    harness-compose--token-overlays))

(ert-deftest harness-ui-compose-thread-is-a-card-with-its-words-under-it ()
  "A reply in a thread is an attachment with a token, [reply 1], on a line of
its own and the words under it: the token shows as a card that says what the
reply is to and quotes it, and a rail goes down beside the words."
  (harness-ui-compose-test-with
    (harness-compose-set "My own words.")
    (let ((att (harness-compose-add-thread (list harness-ui-compose-test--ref))))
      (should (equal 1 (plist-get att :reply)))
      (should (equal "My own words.\n[reply 1]\n" (harness-compose-text)))
      ;; Point is where the words under the card start.
      (should (= (point) harness-compose-end))
      (let* ((cards (harness-ui-compose-test--cards))
             (card (overlay-get (car cards) 'display)))
        (should (= 1 (length cards)))
        (should (string-search "↩ agent's message" card))
        (should (string-search "The build is green." card))
        (should (string-search "The deploy is pending." card))
        (should (string-search "[×]" card))
        ;; The whole quote is the tooltip, and a click shows the message.
        (should (string-search "The deploy is pending." (overlay-get (car cards) 'help-echo)))
        ;; The rail is the box's one bar: on every line of the card.
        (dolist (line (split-string card "\n"))
          (should (string-prefix-p "▎ " line))
          (should (= 1 (cl-count ?▎ line)))))
      ;; The words under it have the rail, and the box's last line too.
      (insert "Why?")
      (harness-compose--keep-tokens)
      (should (cl-some (lambda (ov) (string-search "▎" (format "%s" (overlay-get ov 'line-prefix))))
                       harness-compose--thread-rails))
      (dolist (ov harness-compose--thread-rails)
        (let ((prefix (format "%s" (overlay-get ov 'line-prefix))))
          (should (= 1 (cl-count ?▎ prefix)))
          (should-not (string-search "▌" prefix))))
      ;; Not one of the attachment lines above the box.
      (should-not (string-search "reply" (buffer-substring-no-properties (point-min) harness-compose-start))))))

(ert-deftest harness-ui-compose-thread-rail-gives-way-to-a-bar-of-the-host ()
  "The rail is two columns, a bar and a space; where the host has a bar down
its lines already it is two blanks, so the lines have the one bar, and the
card's words stand where they stood beside the rail."
  (harness-ui-compose-test-with
    (should (equal "▎ " (substring-no-properties (harness-thread-rail))))
    (should (eq 'harness-thread-rail-face (get-text-property 0 'face (harness-thread-rail))))
    (should (equal '(harness-thread-rail-face harness-user-face)
                   (get-text-property 0 'face (harness-thread-rail 'harness-user-face))))
    (should (equal "  " (harness-thread-rail nil t)))
    (should (eq 'harness-user-face (get-text-property 1 'face (harness-thread-rail 'harness-user-face t))))
    (let* ((data (list :refs (list harness-ui-compose-test--ref)))
           (railed (harness-thread-card-lines data 40 "[×]"))
           (blank (harness-thread-card-lines data 40 "[×]" (harness-thread-rail nil t))))
      (should (= 3 (length railed)))
      (should (cl-every (lambda (line) (string-prefix-p "▎ " line)) railed))
      (should (cl-notany (lambda (line) (string-search "▎" line)) blank))
      (should (cl-every (lambda (line) (string-prefix-p "  " line)) blank))
      ;; Nothing but the bar differs: the words, the column they start at, the
      ;; references a click shows.
      (should (equal (mapcar (lambda (line) (substring-no-properties line 2)) railed)
                     (mapcar (lambda (line) (substring-no-properties line 2)) blank)))
      (should (equal (mapcar (lambda (line) (get-text-property 0 'harness-thread-ref line)) railed)
                     (mapcar (lambda (line) (get-text-property 0 'harness-thread-ref line)) blank)))
      (should (string-search "↩ agent's message  [×]" (car blank))))))

(ert-deftest harness-ui-compose-thread-has-one-bar-in-a-box-with-an-accent ()
  "A box with a bar of its own (`harness-compose-insert' :accent) draws a reply's
card and the words under it beside that bar, with no rail: one bar, not two,
the card's words where they stood."
  (harness-ui-compose-test-with
    (setq harness-ui-compose-test--accent 'bold)
    (harness-ui-compose-test--draw)
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    (insert "Why?\nAnd when?")
    (harness-compose--keep-tokens)
    (let ((card (overlay-get (car (harness-ui-compose-test--cards)) 'display)))
      (should (string-search "↩ agent's message" card))
      (should (string-search "The deploy is pending." card))
      (should (string-search "[×]" card))
      (should-not (string-search "▎" card))
      (dolist (line (split-string card "\n"))
        (should (string-prefix-p "  " line))))
    ;; The box's own bar is down every line, in the prefix of the words under
    ;; the card as in that of the lines after the first.
    (should harness-compose--thread-rails)
    (dolist (ov harness-compose--thread-rails)
      (let ((prefix (format "%s" (overlay-get ov 'line-prefix))))
        (should (= 1 (cl-count ?▌ prefix)))
        (should-not (string-search "▎" prefix))
        (should (string-suffix-p "  " prefix))))
    (should (= 1 (cl-count ?▌ (format "%s" (overlay-get harness-compose--indent 'line-prefix)))))
    ;; Back to a box without one, the rail is the bar.
    (setq harness-ui-compose-test--accent nil)
    (harness-ui-compose-test--draw)
    (should (string-search "▎" (overlay-get (car (harness-ui-compose-test--cards)) 'display)))
    (dolist (ov harness-compose--thread-rails)
      (should (= 1 (cl-count ?▎ (format "%s" (overlay-get ov 'line-prefix)))))
      (should-not (string-search "▌" (format "%s" (overlay-get ov 'line-prefix)))))))

(ert-deftest harness-ui-compose-thread-take-splits-the-box-at-the-cards ()
  "The box's own words are the text; each card is an attachment with the words
under it, up to the next card, as its response, ahead of the other
attachments.  A card with nothing under it, and a box of nothing but its
cards' quotes, signal."
  (harness-ui-compose-test-with
    (harness-compose-set "Intro @notes.txt")
    (write-region "x" nil (expand-file-name "notes.txt" dir))
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    (insert "First answer.\nOn two lines.")
    (harness-compose-add-thread (list '(:kind "chat" :node "n-2" :who "plan" :text "Step two")))
    (insert "Second answer.")
    (harness-compose--keep-tokens)
    (should (equal "Intro @notes.txt\n[reply 1]\nFirst answer.\nOn two lines.\n[reply 2]\nSecond answer."
                   (harness-compose-text)))
    (pcase-let ((`(,text . ,atts) (harness-compose-take)))
      (should (equal "Intro @notes.txt" text))
      (should (equal '(1 2) (mapcar (lambda (a) (plist-get a :reply)) (cl-remove-if-not (lambda (a) (plist-get a :thread)) atts))))
      (should (equal '("First answer.\nOn two lines." "Second answer.")
                     (mapcar (lambda (a) (plist-get a :response)) (cl-subseq atts 0 2))))
      ;; The file the words named is attached after the replies.
      (should (equal "notes.txt" (plist-get (nth 2 atts) :name)))
      (should (equal (list harness-ui-compose-test--ref) (plist-get (plist-get (car atts) :thread) :refs)))))
  (harness-ui-compose-test-with
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    (should-error (harness-compose-take) :type 'user-error)
    (insert "Words.")
    (should (equal "" (car (harness-compose-take))))))

(ert-deftest harness-ui-compose-thread-goes-out-as-a-block-of-its-own ()
  "A reply in a thread goes to the harness as a text block holding the words
under the card, with the thread's data as `_harness.thread', and comes back
from there as the block of that reply; queued, it is the same block."
  (harness-ui-compose-test-with
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    (insert "Why?")
    (pcase-let* ((`(,_text . ,atts) (harness-compose-take))
                 (block (harness-compose-attachment-block (car atts)))
                 (read (harness-acp--block-from-acp block)))
      (should (equal "Why?" (plist-get block :text)))
      (should (equal (list harness-ui-compose-test--ref) (plist-get (plist-get (plist-get block :_harness) :thread) :refs)))
      (should (harness-thread-block-p read))
      (should (equal "> The build is green.\n> The deploy is pending.\n\nWhy?" (plist-get read :text)))
      (should (equal (list read) (harness-agent-attachments-to-blocks atts))))))

(ert-deftest harness-ui-compose-thread-comes-back-into-the-box ()
  "A message taken back, its text and its replies as `take' gave them, is laid out
in the box again: the words under each card, and the attachments without them."
  (harness-ui-compose-test-with
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    (insert "Why?")
    (pcase-let ((`(,text . ,atts) (harness-compose-take)))
      (harness-compose-clear)
      (should (equal "" (harness-compose-text)))
      (harness-compose-restore text atts)
      (harness-compose--keep-tokens)
      ;; A line above the card for a message of your own, as a card made here leaves.
      (should (equal "\n[reply 1]\nWhy?" (harness-compose-text)))
      (should (= 1 (length harness-compose-attachments)))
      (should-not (plist-get (car harness-compose-attachments) :response))
      (should (= 1 (length (harness-ui-compose-test--cards))))
      ;; And the next one takes the next number.
      (should (equal 2 (harness-compose--next-reply))))))

(ert-deftest harness-ui-compose-thread-goes-with-its-token ()
  "Removing a card (its ×, the menu, or deleting its token) removes the thread and
leaves the words under it; the token brought back by undo brings it back."
  (harness-ui-compose-test-with
    (let ((att (harness-compose-add-thread (list harness-ui-compose-test--ref))))
      (insert "Why?")
      (harness-compose--keep-tokens)
      (harness-compose-remove-attachment att)
      (should (equal "Why?" (harness-compose-text)))
      (should-not harness-compose-attachments)
      (should-not (harness-ui-compose-test--cards))
      ;; Typing the token again brings the reply back, where it stood.
      (goto-char harness-compose-start)
      (insert "[reply 1]\n")
      (harness-compose--keep-tokens)
      (should (= 1 (length harness-compose-attachments)))
      (should (= 1 (length (harness-ui-compose-test--cards)))))))

(ert-deftest harness-ui-compose-thread-deleted-by-hand-leaves-the-box-tidy ()
  "Deleting a card's token by hand -- C-d at its start, where C-p from the reply puts
point -- gives the reply up as [×] does: the card, the line break it ends with,
and the empty line it left for your message go, the words under it stay.  With
words of your own above it, only the card goes."
  (harness-ui-compose-test-with
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    (execute-kbd-macro "Why?")
    (goto-char (cadr (car (harness-compose--cards))))
    (harness-ui-compose-test--keys "C-d")
    (should (equal "Why?" (harness-compose-text)))
    (should-not harness-compose-attachments)
    (should-not (harness-ui-compose-test--cards)))
  (harness-ui-compose-test-with
    (harness-compose-set "Intro.")
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    (execute-kbd-macro "Why?")
    ;; DEL at the end of the token cuts its last character.
    (goto-char (cddr (car (harness-compose--cards))))
    (harness-ui-compose-test--keys "DEL")
    (should (equal "Intro.\nWhy?" (harness-compose-text)))
    (should-not harness-compose-attachments)))

(ert-deftest harness-ui-compose-thread-removing-the-first-card-keeps-the-words-in-order ()
  "Removing the first of two cards takes the line it left for your own message
with it when nothing is on that line: the words under it are the message's now,
and the second card keeps its own."
  (harness-ui-compose-test-with
    (let ((first (harness-compose-add-thread (list harness-ui-compose-test--ref))))
      (insert "One.")
      (harness-compose-add-thread (list '(:kind "chat" :node "n-2" :who "plan" :text "Step two")))
      (insert "Two.")
      (harness-compose--keep-tokens)
      (should (equal "\n[reply 1]\nOne.\n[reply 2]\nTwo." (harness-compose-text)))
      (harness-compose-remove-attachment first)
      (should (equal "One.\n[reply 2]\nTwo." (harness-compose-text)))
      (should (= 1 (length harness-compose-attachments)))
      (should (= 1 (length (harness-ui-compose-test--cards)))))))

;;;; Your message, and the replies

;; A card in the box leaves a line for your own message above it, and a
;; line for the words of each reply under it.  C-c < moves point between
;; your message and the reply it was in, what is typed from outside the
;; box goes to the area written in last, and the card and the empty
;; areas say which is which.

(defun harness-ui-compose-test-leave-the-box ()
  "Leave the box in one command: point goes to the top of the buffer, the transcript."
  (interactive)
  (goto-char (point-min)))

(ert-deftest harness-ui-compose-card-break-leaves-a-line-for-the-words-above-a-card ()
  "A card's token starts a line, with a line above it for the words that belong
above: your message above the first card, the reply under the card before."
  (should (equal "\n" (harness-compose--card-break "")))
  (should (equal "\n" (harness-compose--card-break "Intro")))
  (should (equal "" (harness-compose--card-break "Intro\n")))
  ;; The empty line of your message is the line.
  (should (equal "" (harness-compose--card-break "\n")))
  ;; A card with no words under it yet: its words need a line.
  (should (equal "\n" (harness-compose--card-break "\n[reply 1]\n")))
  (should (equal "\n" (harness-compose--card-break "Intro\n[reply 12]\n")))
  (should (equal "" (harness-compose--card-break "\n[reply 1]\nWhy?\n"))))

(ert-deftest harness-ui-compose-thread-leaves-a-line-for-each-area ()
  "The first card of an empty box leaves a line above it, for a message of your
own; a card after one with nothing under it leaves a line for those words; a
card after your words or the reply's needs only its line break.  Point is
where the words of the reply start."
  (harness-ui-compose-test-with
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    (should (equal "\n[reply 1]\n" (harness-compose-text)))
    (should (= (point) harness-compose-end))
    (harness-compose-add-thread (list '(:kind "chat" :node "n-2" :who "plan" :text "Step two")))
    (should (equal "\n[reply 1]\n\n[reply 2]\n" (harness-compose-text)))
    (should (= (point) harness-compose-end))
    (insert "Second.")
    (harness-compose--keep-tokens)
    (should (equal "\n[reply 1]\n\n[reply 2]\nSecond." (harness-compose-text)))
    ;; Both were taken, and nothing of the lines they left reaches the message.
    (goto-char (+ harness-compose-start (length "\n[reply 1]\n")))
    (insert "First.")
    (pcase-let ((`(,text . ,atts) (harness-compose-take)))
      (should (equal "" text))
      (should (equal '("First." "Second.") (mapcar (lambda (a) (plist-get a :response)) atts)))))
  ;; Your own words first: the card follows them, a line break between, as ever.
  (harness-ui-compose-test-with
    (harness-compose-set "Intro.")
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    (should (equal "Intro.\n[reply 1]\n" (harness-compose-text)))
    (insert "Why?")
    (harness-compose-add-thread (list '(:kind "chat" :node "n-2" :who "plan" :text "Step two")))
    (should (equal "Intro.\n[reply 1]\nWhy?\n[reply 2]\n" (harness-compose-text)))))

(ert-deftest harness-ui-compose-c-c-<-moves-between-your-message-and-the-reply ()
  "C-c < moves point out of the reply, to your own message on the line above the
first card, and back into the reply, at the end of its words.  What is typed in
each is that area's: sending splits the box at the card, your message and the
reply with its words.  Typed through the command loop."
  (harness-ui-compose-test-with
    (should (eq 'harness-compose-toggle-reply (key-binding (kbd "C-c <"))))
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    (execute-kbd-macro "Why?")
    (should (equal "\n[reply 1]\nWhy?" (harness-compose-text)))
    ;; Out of the reply: your message, on a line of its own, nothing on it yet.
    (harness-ui-compose-test--keys "C-c <")
    (should (= (point) harness-compose-start))
    (execute-kbd-macro "Also, run the tests.")
    (should (equal "Also, run the tests.\n[reply 1]\nWhy?" (harness-compose-text)))
    ;; Back into the reply: the end of its words.
    (harness-ui-compose-test--keys "C-c <")
    (should (= (point) harness-compose-end))
    (execute-kbd-macro " Thanks.")
    (should (equal "Also, run the tests.\n[reply 1]\nWhy? Thanks." (harness-compose-text)))
    ;; And out again, to the end of your message.
    (harness-ui-compose-test--keys "C-c <")
    (should (= (point) (+ harness-compose-start (length "Also, run the tests."))))
    (pcase-let ((`(,text . ,atts) (harness-compose-take)))
      (should (equal "Also, run the tests." text))
      (should (equal '("Why? Thanks.") (mapcar (lambda (a) (plist-get a :response)) atts))))
    ;; Its two halves, and what a box with no card says.
    (goto-char harness-compose-end)
    (harness-compose-leave-reply)
    (should (= (point) (+ harness-compose-start (length "Also, run the tests."))))
    (harness-compose-enter-reply)
    (should (= (point) harness-compose-end)))
  (harness-ui-compose-test-with
    (harness-compose-set "just words")
    (goto-char harness-compose-end)
    (dolist (command '(harness-compose-toggle-reply harness-compose-leave-reply harness-compose-enter-reply))
      (let ((err (should-error (funcall command) :type 'user-error)))
        (should (string-search "C-c >" (cadr err)))))
    (should (equal "just words" (harness-compose-text)))))

(ert-deftest harness-ui-compose-ordinary-motion-leaves-a-reply-too ()
  "The line of your message is text, so M-< goes to it from a reply, being the top
of the box, and C-p goes up from the reply to the card, one of its edges."
  (harness-ui-compose-test-with
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    (execute-kbd-macro "Why?")
    (harness-ui-compose-test--keys "M-<")
    (should (= (point) harness-compose-start))
    (execute-kbd-macro "Intro")
    (should (equal "Intro\n[reply 1]\nWhy?" (harness-compose-text)))
    ;; Up from the reply: onto the card, at an edge of it.
    (goto-char harness-compose-end)
    (harness-ui-compose-test--keys "C-p")
    (let ((card (car (harness-compose--cards))))
      (should (memq (point) (list (cadr card) (cddr card)))))))

(ert-deftest harness-ui-compose-typing-against-a-card-goes-next-to-it ()
  "A card is no text to type against.  Typed at its start, which is where
moving up from its reply puts point, a printable key goes to the end of the area
above the card -- your message, made a line of its own if the box had none --
and at its end to the start of its reply's words."
  (harness-ui-compose-test-with
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    (execute-kbd-macro "Why?")
    ;; At the end of the card: the start of its reply, on the line under it.
    (goto-char (cddr (car (harness-compose--cards))))
    (execute-kbd-macro "a")
    (should (equal "\n[reply 1]\naWhy?" (harness-compose-text)))
    (should (= (point) (+ harness-compose-start (length "\n[reply 1]\na"))))
    ;; At its start: your message above, on the line there is for it.
    (goto-char (cadr (car (harness-compose--cards))))
    (execute-kbd-macro "b")
    (should (equal "b\n[reply 1]\naWhy?" (harness-compose-text)))
    ;; A second card: at its start, the end of the words of the first reply.
    (goto-char harness-compose-end)
    (harness-compose-add-thread (list '(:kind "chat" :node "n-2" :who "plan" :text "Step two")))
    (execute-kbd-macro "Two.")
    (goto-char (cadr (cadr (harness-compose--cards))))
    (execute-kbd-macro "c")
    (should (equal "b\n[reply 1]\naWhy?c\n[reply 2]\nTwo." (harness-compose-text)))
    (should (= 2 (length (harness-ui-compose-test--cards)))))
  ;; A box that starts with its card, and two cards with nothing between them.
  (harness-ui-compose-test-with
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    (harness-compose-set "[reply 1]\n[reply 2]\nTwo.")
    (setq harness-compose-attachments
          (list (list :thread (list :refs (list harness-ui-compose-test--ref)) :reply 1)
                (list :thread (list :refs (list '(:kind "chat" :node "n-2" :who "plan" :text "Step two"))) :reply 2)))
    (harness-compose--keep-tokens)
    (should (= 2 (length (harness-ui-compose-test--cards))))
    (goto-char (cadr (cadr (harness-compose--cards))))
    (execute-kbd-macro "x")
    (should (equal "[reply 1]\nx\n[reply 2]\nTwo." (harness-compose-text)))
    (goto-char (cadr (car (harness-compose--cards))))
    (execute-kbd-macro "y")
    (should (equal "y\n[reply 1]\nx\n[reply 2]\nTwo." (harness-compose-text)))))

(ert-deftest harness-ui-compose-typing-from-outside-goes-to-the-area-written-in-last ()
  "Typing from outside the box, RET and C-c < go to the end of the area point was
in last: your message, or a reply, whatever was read or clicked between.  A box
with no card, or whose reply was taken away, takes it at its end."
  (harness-ui-compose-test-with
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    (execute-kbd-macro "Why?")
    ;; Written in the reply last: the transcript's typing goes there.
    (goto-char (point-min))
    (execute-kbd-macro "!")
    (should (equal "\n[reply 1]\nWhy?!" (harness-compose-text)))
    ;; Out of the reply, and out of the box by M-< twice, the second reaching the buffer's top.
    (harness-ui-compose-test--keys "C-c <")
    (execute-kbd-macro "Intro")
    (harness-ui-compose-test--keys "M-< M-<")
    (should-not (harness-compose-in-p))
    (execute-kbd-macro ".")
    (should (equal "Intro.\n[reply 1]\nWhy?!" (harness-compose-text)))
    (should (= (point) (+ harness-compose-start (length "Intro."))))
    ;; RET from outside jumps in, to the same place, and types nothing.
    (goto-char (point-min))
    (harness-ui-compose-test--keys "RET")
    (should (= (point) (+ harness-compose-start (length "Intro."))))
    (should (equal "Intro.\n[reply 1]\nWhy?!" (harness-compose-text)))
    ;; C-c < from outside goes in the same way, then it is the toggle again: into the reply.
    (harness-ui-compose-test--keys "M-< M-<")
    (should-not (harness-compose-in-p))
    (harness-ui-compose-test--keys "C-c <")
    (should (= (point) (+ harness-compose-start (length "Intro."))))
    (harness-ui-compose-test--keys "C-c <")
    (should (= (point) harness-compose-end))
    ;; From the reply, out by M->, which from the end of the box goes on to the buffer's: back to the reply.
    (should (= (point) harness-compose-end))
    (harness-ui-compose-test--keys "M->")
    (should-not (harness-compose-in-p))
    (execute-kbd-macro "?")
    (should (equal "Intro.\n[reply 1]\nWhy?!?" (harness-compose-text)))
    ;; The reply taken away: the end of the box.
    (harness-compose-remove-attachment (car harness-compose-attachments))
    (goto-char (point-min))
    (execute-kbd-macro "#")
    (should (equal "Intro.\nWhy?!?#" (harness-compose-text)))))

(ert-deftest harness-ui-compose-c-c-<-goes-back-into-the-reply-you-left ()
  "With several replies, C-c < out of one and back goes into that one, and what is
typed from outside goes to the one written in last."
  (harness-ui-compose-test-with
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    (execute-kbd-macro "One.")
    (harness-compose-add-thread (list '(:kind "chat" :node "n-2" :who "plan" :text "Step two")))
    (execute-kbd-macro "Two.")
    (should (equal "\n[reply 1]\nOne.\n[reply 2]\nTwo." (harness-compose-text)))
    ;; In the first reply, then out and back: the first.
    (goto-char (+ harness-compose-start (length "\n[reply 1]\nOn")))
    (harness-ui-compose-test--keys "C-f")
    (harness-ui-compose-test--keys "C-c <")
    (should (= (point) harness-compose-start))
    (harness-ui-compose-test--keys "C-c <")
    (should (= (point) (+ harness-compose-start (length "\n[reply 1]\nOne."))))
    (execute-kbd-macro "!")
    (should (equal "\n[reply 1]\nOne.!\n[reply 2]\nTwo." (harness-compose-text)))
    ;; Left to the transcript from it, in one command, typing goes there, not to the last.
    (execute-kbd-macro (kbd "M-x harness-ui-compose-test-leave-the-box RET"))
    (should-not (harness-compose-in-p))
    (execute-kbd-macro "?")
    (should (equal "\n[reply 1]\nOne.!?\n[reply 2]\nTwo." (harness-compose-text)))
    ;; In the second, the second.
    (goto-char harness-compose-end)
    (harness-ui-compose-test--keys "C-b C-f C-c < C-c <")
    (should (= (point) harness-compose-end))
    ;; Both replies, and your message, are sent with their words.
    (pcase-let ((`(,text . ,atts) (harness-compose-take)))
      (should (equal "" text))
      (should (equal '("One.!?" "Two.") (mapcar (lambda (a) (plist-get a :response)) atts))))))

(ert-deftest harness-ui-compose-leaving-a-reply-makes-the-line-for-your-message ()
  "A box whose card is its first text, one taken back with nothing before it, or
whose words run on into the token, gets the line your message needs when point
leaves the reply: a line break before the token, point on the line above."
  (harness-ui-compose-test-with
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    (harness-compose-set "[reply 1]\nWhy?")
    (harness-compose--keep-tokens)
    (should (= 1 (length (harness-ui-compose-test--cards))))
    (goto-char harness-compose-end)
    (harness-ui-compose-test--keys "C-c <")
    (should (equal "\n[reply 1]\nWhy?" (harness-compose-text)))
    (should (= (point) harness-compose-start))
    (should (= 1 (length (harness-ui-compose-test--cards))))
    ;; Typing from outside into your message makes it too: no text against the card.
    (harness-compose-set "[reply 1]\nWhy?")
    (harness-compose--keep-tokens)
    (goto-char harness-compose-end)
    (harness-ui-compose-test--keys "C-c <")
    (harness-ui-compose-test--keys "M-< M-<")
    (should-not (harness-compose-in-p))
    (execute-kbd-macro "Hi")
    (should (equal "Hi\n[reply 1]\nWhy?" (harness-compose-text)))
    ;; Words that ran on into the token.
    (harness-compose-set "XY[reply 1]\nWhy?")
    (harness-compose--keep-tokens)
    (goto-char harness-compose-end)
    (harness-ui-compose-test--keys "C-c <")
    (should (equal "XY\n[reply 1]\nWhy?" (harness-compose-text)))
    (should (= (point) (+ harness-compose-start 2)))))

(defun harness-ui-compose-test--card-text ()
  "Return what the first card of the box shows, as text."
  (substring-no-properties (overlay-get (car (harness-ui-compose-test--cards)) 'display)))

(defun harness-ui-compose-test--area-hints ()
  "Return the empty areas the box names: (OFFSET . TEXT), OFFSET from the box's start."
  (mapcar (lambda (ov) (cons (- (overlay-start ov) harness-compose-start)
                             (substring-no-properties (overlay-get ov 'before-string))))
          harness-compose--area-hints))

(ert-deftest harness-ui-compose-the-card-says-how-to-leave-its-reply ()
  "The card of the reply point is in names the key that moves out to your message;
with point in your message, the card of the reply it goes back into names it;
outside the box, or with the hints off, nothing.  A host drawing the box
again, point nowhere in it meanwhile, leaves it as it was."
  (harness-ui-compose-test-with
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    (execute-kbd-macro "Why?")
    (should (string-search "[×]  C-c < your message" (harness-ui-compose-test--card-text)))
    (harness-ui-compose-test--keys "C-c <")
    (should (string-search "[×]  C-c < back to the reply" (harness-ui-compose-test--card-text)))
    ;; The host draws the box again: the hint stays.
    (harness-ui-compose-test--draw)
    (should (string-search "C-c < back to the reply" (harness-ui-compose-test--card-text)))
    (harness-ui-compose-test--keys "C-c <")
    (harness-ui-compose-test--draw)
    (should (string-search "C-c < your message" (harness-ui-compose-test--card-text)))
    ;; Out of the box, nothing to say.
    (harness-ui-compose-test--keys "M-< M-<")
    (should-not (string-search "C-c <" (harness-ui-compose-test--card-text)))
    ;; Turned off.
    (let ((harness-compose-reply-hints nil))
      (harness-ui-compose-test--keys "C-c <")
      (should (harness-compose-in-p))
      (should-not (string-search "C-c <" (harness-ui-compose-test--card-text))))
    ;; Only the card of the reply that goes in says so, with several.
    (goto-char harness-compose-end)
    (harness-compose-add-thread (list '(:kind "chat" :node "n-2" :who "plan" :text "Step two")))
    (execute-kbd-macro "Two.")
    (goto-char harness-compose-start)
    (harness-ui-compose-test--keys "C-f")
    (let ((cards (harness-ui-compose-test--cards)))
      (should (= 2 (length cards)))
      (should-not (string-search "C-c <" (substring-no-properties (overlay-get (car cards) 'display))))
      (should (string-search "C-c < back to the reply" (substring-no-properties (overlay-get (cadr cards) 'display)))))))

(ert-deftest harness-ui-compose-empty-areas-say-what-they-are ()
  "Your message, on its line above a card, and a reply with no words yet each say
what they are, as the empty box does, until words are typed in them."
  (harness-ui-compose-test-with
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    ;; "\n[reply 1]\n": your message at its start, the reply at its end.
    (should (equal '((0 . "Message…") (11 . "Reply…")) (harness-ui-compose-test--area-hints)))
    (execute-kbd-macro "Why?")
    (should (equal '((0 . "Message…")) (harness-ui-compose-test--area-hints)))
    (harness-ui-compose-test--keys "C-c <")
    (execute-kbd-macro "Hi")
    (should-not (harness-ui-compose-test--area-hints))
    ;; The words deleted, and the area says so again.
    (harness-ui-compose-test--keys "DEL DEL")
    (should (equal '((0 . "Message…")) (harness-ui-compose-test--area-hints)))
    (harness-compose-set "")
    (should-not (harness-ui-compose-test--area-hints)))
  ;; A reply with a line of its own before the next card.
  (harness-ui-compose-test-with
    (harness-compose-set "Intro.")
    (harness-compose-add-thread (list harness-ui-compose-test--ref))
    (harness-compose-add-thread (list '(:kind "chat" :node "n-2" :who "plan" :text "Step two")))
    (should (equal "Intro.\n[reply 1]\n\n[reply 2]\n" (harness-compose-text)))
    (should (equal '((17 . "Reply…") (28 . "Reply…")) (harness-ui-compose-test--area-hints)))
    (execute-kbd-macro "Second.")
    (should (equal '((17 . "Reply…")) (harness-ui-compose-test--area-hints)))))

;;;; Links dropped on the box

(ert-deftest harness-ui-compose-dropped-link-downloads-behind-a-chip ()
  (skip-unless (executable-find "curl"))
  (harness-ui-compose-test-with
    (let* ((body (concat harness-test-png (make-string 30000 ?p)))
           (server (harness-test-http-serve
                    `(("/images/cat.png" 200 (("Content-Type" . "image/png")) ,body :chunks 5 :delay 0.2)
                      ("/again/cat.png" 200 (("Content-Type" . "image/png")) ,body))))
           (url (harness-test-http-url server "/images/cat.png")))
      (unwind-protect
          (let ((start (float-time)))
            (harness-compose-set "look")
            (goto-char harness-compose-start)
            ;; The drop returns at once: curl downloads in the background.
            (should (eq 'private (dnd-handle-multiple-urls (selected-window) (list url) 'private)))
            (should (< (- (float-time) start) 0.5))
            (let* ((pending (harness-ui-compose-test--pending))
                   (ov (cdr (assoc (plist-get pending :id) harness-compose--progress))))
              (should (equal "cat.png" (plist-get pending :name)))
              (should (equal url (plist-get pending :url)))
              ;; The chip is an overlay over one character of the tail.
              (should (overlayp ov))
              (should (eq (current-buffer) (overlay-buffer ov)))
              (should (string-match-p "cat\\.png" (overlay-get ov 'display)))
              ;; The message waits for the download.
              (should-error (harness-compose-take) :type 'user-error)
              ;; The progress ticks redraw the overlay, never the text.
              (let ((tick (buffer-chars-modified-tick)))
                (harness-test-wait (lambda () (string-match-p "[0-9]+% of" (overlay-get ov 'display))) 5 "progress")
                (should (= tick (buffer-chars-modified-tick)))))
            (harness-test-wait #'harness-ui-compose-test--settled 10 "the download")
            (let ((att (car harness-compose-attachments)))
              (should (= 1 (length harness-compose-attachments)))
              (should (equal "image/png" (plist-get att :mime)))
              (should (equal url (plist-get att :url)))
              (should (equal (expand-file-name "downloads/cat.png" harness-state-directory) (plist-get att :path)))
              (should (equal body (harness-ui-compose-test--bytes (plist-get att :path))))
              (should (= (length body) (plist-get att :size)))
              (should (equal "image" (plist-get (harness-compose-attachment-block att) :type)))
              ;; Its token goes at the end of the box, wherever point
              ;; went while it downloaded.
              (should (equal "image 1" (plist-get att :label)))
              (should (equal "look [image 1] " (harness-compose-text))))
            (should-not harness-compose--progress)
            (should-not (directory-files (expand-file-name "downloads/" harness-state-directory) nil "\\`\\.partial"))
            (goto-char (point-min))
            (should (search-forward "cat.png (" nil t))
            ;; The same link again is attached already; another file of that
            ;; name gets a name of its own.
            (dnd-handle-multiple-urls (selected-window) (list url) 'private)
            (should (= 1 (length harness-compose-attachments)))
            (dnd-handle-multiple-urls (selected-window) (list (harness-test-http-url server "/again/cat.png")) 'private)
            (harness-test-wait #'harness-ui-compose-test--settled 10 "the second download")
            (should (equal (expand-file-name "downloads/cat-1.png" harness-state-directory)
                           (plist-get (cadr harness-compose-attachments) :path)))
            (should (equal "cat-1.png" (plist-get (cadr harness-compose-attachments) :name)))
            (should (equal "look [image 1] [image 2] " (harness-compose-text))))
        (delete-process server)))))

(ert-deftest harness-ui-compose-dropped-link-to-a-page-goes-in-as-text ()
  (skip-unless (executable-find "curl"))
  (harness-ui-compose-test-with
    (let* ((server (harness-test-http-serve
                    '(("/article" 200 (("Content-Type" . "text/html; charset=utf-8")) "<html>an article</html>"))))
           (url (harness-test-http-url server "/article")))
      (unwind-protect
          (progn
            (goto-char harness-compose-end)
            (insert "see")
            (let ((messages (harness-ui-compose-test-messages
                              (dnd-handle-multiple-urls (selected-window) (list url) 'private)
                              (harness-test-wait #'harness-ui-compose-test--settled 10 "the page"))))
              (should (cl-some (lambda (m) (string-match-p "is a web page" m)) messages)))
            (should-not harness-compose-attachments)
            (should (equal (concat "see " url) (harness-compose-text)))
            (should-not (directory-files (expand-file-name "downloads/" harness-state-directory) nil "\\`[^.]")))
        (delete-process server)))))

(ert-deftest harness-ui-compose-failed-download-says-why ()
  (skip-unless (executable-find "curl"))
  (harness-ui-compose-test-with
    (let* ((server (harness-test-http-serve '()))
           (url (harness-test-http-url server "/gone.png")))
      (unwind-protect
          (let ((messages (harness-ui-compose-test-messages
                            (dnd-handle-multiple-urls (selected-window) (list url) 'private)
                            (harness-test-wait #'harness-ui-compose-test--settled 10 "the failure"))))
            (should-not harness-compose-attachments)
            (should (cl-some (lambda (m) (string-match-p "Could not download .*gone\\.png: the server answered HTTP 404" m))
                             messages))
            (should-not harness-compose--progress))
        (delete-process server)))))

(ert-deftest harness-ui-compose-download-stops-when-removed-cleared-or-killed ()
  (skip-unless (executable-find "curl"))
  (harness-ui-compose-test-with
    (let* ((server (harness-test-http-serve
                    `(("/slow.webm" 200 (("Content-Type" . "video/webm")) ,(make-string 40000 ?w) :chunks 2 :pause-after 1))))
           (url (harness-test-http-url server "/slow.webm"))
           (started (lambda ()
                      (harness-compose-download url)
                      (let ((dl (plist-get (harness-ui-compose-test--pending) :download)))
                        (harness-test-wait (lambda () (> (harness-http-download-received dl) 0)) 10 "the first bytes")
                        dl))))
      (unwind-protect
          (progn
            ;; ×
            (let ((dl (funcall started)))
              (harness-compose-cancel-download (plist-get (harness-ui-compose-test--pending) :id))
              (should-not harness-compose-attachments)
              (should (harness-download-cancelled dl))
              (should-not (file-exists-p (harness-download-file dl)))
              (harness-test-wait (lambda () (not (process-live-p (harness-download-process dl)))) 5 "curl gone"))
            ;; Clearing the box.
            (let ((dl (funcall started)))
              (harness-compose-clear)
              (should-not harness-compose-attachments)
              (should (harness-download-cancelled dl)))
            ;; Killing the buffer.
            (let ((dl (funcall started)))
              (kill-buffer (current-buffer))
              (should (harness-download-cancelled dl))
              (should-not (file-exists-p (harness-download-file dl)))))
        (delete-process server)))))

(ert-deftest harness-ui-compose-dropped-data-links-attach ()
  (harness-ui-compose-test-with
    (dnd-handle-multiple-urls (selected-window)
                              (list (concat "data:image/png;base64," (base64-encode-string harness-test-png t))
                                    "data:,hello%20world")
                              'private)
    (should (equal '("dropped.png" "dropped.txt") (mapcar (lambda (a) (plist-get a :name)) harness-compose-attachments)))
    (should (equal '("image/png" "text/plain") (mapcar (lambda (a) (plist-get a :mime)) harness-compose-attachments)))
    (should (equal harness-test-png (harness-ui-compose-test--bytes (plist-get (car harness-compose-attachments) :path))))
    (should (equal "hello world" (harness-ui-compose-test--bytes (plist-get (cadr harness-compose-attachments) :path))))))

(ert-deftest harness-ui-compose-drop-takes-the-image-the-browser-drags ()
  ;; A browser dragging an image inside a link drops the link; the image
  ;; is the only one in the drop's HTML, or Firefox's file promise.
  (harness-ui-compose-test-with
    (let ((offered nil))
      (cl-letf (((symbol-function 'harness-compose--drop-text) (lambda (type) (cdr (assoc type offered)))))
        (should (equal '("https://site.example/a/cat.jpg") (harness-compose--dropped-media "https://site.example/a/cat.jpg")))
        (should (equal '("https://site.example/page") (harness-compose--dropped-media "https://site.example/page")))
        (setq offered '(("text/html" . "<a href=\"https://site.example/page\"><img alt=\"a cat\" src=\"/img/cat.jpg?w=200&amp;h=100\"></a>")))
        (should (equal '("https://site.example/img/cat.jpg?w=200&h=100") (harness-compose--dropped-media "https://site.example/page")))
        ;; A link to an image file is taken as it is, the full-size one.
        (should (equal '("https://site.example/full.png") (harness-compose--dropped-media "https://site.example/full.png")))
        (setq offered '(("text/html" . "<img src='data:image/gif;base64,R0lGOD'>")))
        (should (equal '("data:image/gif;base64,R0lGOD") (harness-compose--dropped-media "https://site.example/page")))
        ;; Two images: the drop says nothing of which.
        (setq offered '(("text/html" . "<img src=\"/1.png\"><img src=\"/2.png\">")))
        (should (equal '("https://site.example/page") (harness-compose--dropped-media "https://site.example/page")))
        (setq offered '(("application/x-moz-file-promise-url" . "https://cdn.example/x/9f8e")
                        ("application/x-moz-file-promise-dest-filename" . "sunset.webp")
                        ("text/html" . "<img src=\"/other.png\">")))
        (should (equal '("https://cdn.example/x/9f8e" . "sunset.webp") (harness-compose--dropped-media "https://site.example/page")))))))

(ert-deftest harness-ui-compose-dropped-text-goes-in-the-box ()
  (harness-ui-compose-test-with
    (goto-char (point-min))
    (harness-compose--drop-utf8 (selected-window) 'copy (encode-coding-string "héllo" 'utf-8))
    (should (equal "héllo" (harness-compose-text)))
    ;; Dropped inside the box, it goes where it was dropped.
    (goto-char (+ harness-compose-start 1))
    (harness-compose--drop-utf16 (selected-window) 'copy (encode-coding-string "XY" (if (eq (byteorder) ?B) 'utf-16be 'utf-16le)))
    (should (equal "hXYéllo" (harness-compose-text)))
    (goto-char (point-min))
    (should (eq 'copy (harness-compose--drop-plain (selected-window) 'copy "a\r\nb")))
    (should (equal "hXYélloa\nb" (harness-compose-text)))))

(ert-deftest harness-ui-compose-drop-handlers-stay-in-the-buffer ()
  (harness-ui-compose-test-with
    (should (eq 'harness-compose-dnd-download (cdr (assoc "^\\(?:https?\\|ftps?\\)://" dnd-protocol-alist))))
    (should-not (rassq 'harness-compose-dnd-download (default-value 'dnd-protocol-alist)))
    (when (boundp 'x-dnd-types-alist)
      (should (eq 'harness-compose--drop-image (cdr (assoc "image/png" x-dnd-types-alist))))
      (should (eq 'harness-compose--drop-utf8 (cdr (assoc "UTF8_STRING" x-dnd-types-alist))))
      (should-not (assoc "image/png" (default-value 'x-dnd-types-alist)))
      ;; Links first, then images, then text.
      (let ((known x-dnd-known-types))
        (should (< (cl-position "text/uri-list" known :test #'equal) (cl-position "image/png" known :test #'equal)))
        (should (< (cl-position "image/png" known :test #'equal) (cl-position "UTF8_STRING" known :test #'equal))))
      (should-not (member "image/png" (default-value 'x-dnd-known-types)))
      (should (eq 'harness-compose--drop-direct-save x-dnd-direct-save-function))
      ;; An image dropped as data is saved and attached.
      (cl-letf (((symbol-function 'x-dnd-current-type) (lambda (_w) "image/png")))
        (harness-compose--drop-image (selected-window) 'copy harness-test-png))
      (should (equal "image/png" (plist-get (car harness-compose-attachments) :mime)))
      (should (equal harness-test-png (harness-ui-compose-test--bytes (plist-get (car harness-compose-attachments) :path))))
      ;; X direct save: the file goes among the downloads, then attaches.
      (let ((path (harness-compose--drop-direct-save t "../a picture.png")))
        (should (equal (expand-file-name "downloads/_a picture.png" harness-state-directory) path))
        (with-temp-file path (insert "x"))
        (harness-compose--drop-direct-save nil path)
        (should (equal path (plist-get (cadr harness-compose-attachments) :path)))))))

(ert-deftest harness-ui-compose-dropped-link-with-junk-still-downloads ()
  ;; A drop can carry a BOM, a newline, a tab or a NUL around the link
  ;; (the class of \"URL rejected: No host present\": curl reads what the
  ;; message does not show).  The box scrubs it, so the file arrives all
  ;; the same and the attachment keeps the clean address.
  (skip-unless (executable-find "curl"))
  (harness-ui-compose-test-with
    (let* ((server (harness-test-http-serve
                    `(("/junk.png" 200 (("Content-Type" . "image/png")) ,harness-test-png))))
           (url (harness-test-http-url server "/junk.png")))
      (unwind-protect
          (progn
            (harness-compose-download (concat "\ufeff\t" url "\r\n\0") "junk.png")
            (should (harness-ui-compose-test--pending))
            (harness-test-wait #'harness-ui-compose-test--settled 10 "the download")
            (let ((att (car harness-compose-attachments)))
              (should (equal url (plist-get att :url)))
              (should (equal "image/png" (plist-get att :mime)))
              (should (equal harness-test-png (harness-ui-compose-test--bytes (plist-get att :path))))))
        (delete-process server)))))

(ert-deftest harness-ui-compose-link-with-no-host-is-refused-clearly ()
  ;; No curl error for a link the box cannot fetch: it says so itself,
  ;; with the link shown as it is, escapes and all.
  (harness-ui-compose-test-with
    (let ((message (error-message-string
                    (should-error (harness-compose-download "https://") :type 'user-error))))
      (should (string-match-p "not a link I can fetch" message))
      (should (string-match-p "\"https://\"" message)))
    (should-not harness-compose-attachments)
    (should-not (harness-ui-compose-test--pending))))

;;;; Chips

(ert-deftest harness-ui-compose-chips-show-thumbnails ()
  (harness-ui-compose-test-with
    (let* ((clip (harness-media-ring-save harness-test-png "image/png"))
           (notes (expand-file-name "notes.txt" dir))
           (video (expand-file-name "clip.mp4" dir))
           (callback nil)
           (thumb (expand-file-name "thumb.png" dir)))
      (with-temp-file notes (insert "notes"))
      (with-temp-file video (insert "not a video"))
      (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                ((symbol-function 'harness-ui-media-video-thumbnail)
                 (lambda (_path &optional cb) (if (file-exists-p thumb) thumb (setq callback cb) nil))))
        (let ((image-chip (harness-compose--chip clip))
              (notes-chip (harness-compose--chip (harness-compose--file-attachment notes))))
          ;; An image shows itself, scaled to the thumbnail height.
          (should (eq 'image (car-safe (get-text-property 0 'display image-chip))))
          (should (equal (plist-get clip :path) (plist-get (cdr (get-text-property 0 'display image-chip)) :file)))
          (should (plist-get (cdr (get-text-property 0 'display image-chip)) :max-height))
          ;; A capture goes by its name, a project file by its path in the project.
          (should (string-match-p (regexp-quote (plist-get clip :name)) image-chip))
          (should-not (string-match-p "clips/" image-chip))
          (should-not (get-text-property 0 'display notes-chip))
          (should (string-prefix-p "notes.txt (" notes-chip)))
        ;; A video shows its thumbnail once the media module made it.
        (let ((att (harness-compose--file-attachment video)))
          (should (equal "video/mp4" (plist-get att :mime)))
          (harness-compose--attach att)
          (harness-compose-redraw)
          (should-not (get-text-property 0 'display (harness-compose--chip att)))
          (should (functionp callback))
          (copy-file (plist-get clip :path) thumb)
          (let ((draws harness-ui-compose-test--draws))
            (funcall callback)
            (should (> harness-ui-compose-test--draws draws)))
          (should (equal thumb (plist-get (cdr (get-text-property 0 'display (harness-compose--chip att))) :file))))
        ;; No thumbnails asked for, or none possible.
        (let ((harness-compose-thumbnail-lines 0))
          (should-not (get-text-property 0 'display (harness-compose--chip clip))))
        ;; A narrow chip keeps a third of its room for the thumbnail at most.
        (should (<= (plist-get (cdr (get-text-property 0 'display (harness-compose--chip clip 6))) :max-width) 2)))
      (should-not (get-text-property 0 'display (harness-compose--chip clip))))))

;;;; Laying the attachments out

(defconst harness-ui-compose-test--deep
  "src/components/a-long-directory-name/another-directory/the-file.tsx"
  "A file deep in the project: its path fits 80 columns, not 40.")

(defun harness-ui-compose-test--shown (start end)
  "Return the text from START to END as it shows.
An overlay's display string, a download's progress, stands in for the
text under it."
  (let ((parts nil) (pos start))
    (while (< pos end)
      (let* ((ov (cl-find-if (lambda (o) (overlay-get o 'display)) (overlays-at pos)))
             (next (min end (if ov (overlay-end ov) (next-overlay-change pos)))))
        (push (if ov (overlay-get ov 'display) (buffer-substring-no-properties pos next)) parts)
        (setq pos next)))
    (substring-no-properties (apply #'concat (nreverse parts)))))

(defun harness-ui-compose-test--attachment-lines (window)
  "Return the attachment lines of the test host as (TEXT COLUMNS INDENT).
TEXT is a line as it shows, COLUMNS how wide it is in WINDOW and
INDENT how far in WINDOW its chip starts."
  (save-excursion
    (goto-char (point-min))
    (forward-line 1)
    (let ((inhibit-field-text-motion t)   ; The box's prompt is a field.
          (end (save-excursion (goto-char harness-compose-start) (pos-bol)))
          (lines nil))
      (while (< (point) end)
        (let ((chip (cl-loop for pos from (point) below (line-end-position)
                             when (or (get-text-property pos 'button)
                                      (get-text-property pos 'harness-compose-pending))
                             return pos)))
          (push (list (harness-ui-compose-test--shown (point) (line-end-position))
                      (car (window-text-pixel-size window (point) (line-end-position)))
                      (car (window-text-pixel-size window (point) chip)))
                lines))
        (forward-line 1))
      (nreverse lines))))

(defun harness-ui-compose-test--attach-all-kinds (dir)
  "Attach one of each kind and return the path of the file deep in DIR.
That file, a short one, an image and a page pasted and a download under
way.  `harness-state-directory' must be outside DIR, the project, so
that the files go by their paths in it."
  (let ((deep (expand-file-name harness-ui-compose-test--deep dir))
        (notes (expand-file-name "notes.txt" dir)))
    (make-directory (file-name-directory deep) t)
    (with-temp-file deep (insert "deep"))
    (with-temp-file notes (insert "notes"))
    (harness-compose--attach (harness-compose--file-attachment deep))
    (harness-compose--attach (harness-compose--file-attachment notes))
    (harness-compose--attach (harness-media-ring-save harness-test-png "image/png"))
    (harness-compose--attach (harness-media-ring-save "<p>pasted</p>" "text/html"))
    ;; A download that never ends: no curl behind it.
    (setq harness-compose-attachments
          (append harness-compose-attachments
                  (list (list :pending t :id "dl" :name "a-download-1.2.3.tar.gz"
                              :url "https://example.com/releases/a-download-1.2.3.tar.gz"))))
    (harness-compose-redraw)
    deep))

(ert-deftest harness-ui-compose-attachments-go-one-a-line ()
  "Every attachment has a line of its own, fitted to the window.
Files, captures and downloads alike: the names line up under the
paperclip's, a name too long is shortened in the middle, keeping its
start and its file's name, and a wide window shows every name whole."
  (harness-ui-compose-test-with
    (let* ((harness-state-directory (file-name-as-directory (expand-file-name "state" dir)))
           (window (selected-window))
           (side (split-window window 40 'right))
           (deep (harness-ui-compose-test--attach-all-kinds dir))
           (names (mapcar #'harness-compose--chip-name harness-compose-attachments)))
      (should (equal harness-ui-compose-test--deep (car names)))
      ;; Shown in the narrow window alone.
      (set-window-buffer side (current-buffer))
      (set-window-buffer window (get-buffer-create "*scratch*"))
      (harness-compose-redraw)
      (let ((lines (harness-ui-compose-test--attachment-lines side)))
        (should (= 5 (length lines)))
        (pcase-dolist (`(,text ,columns ,indent) lines)
          (should (= 1 (cl-count ?× text)))
          (should (< columns (window-body-width side)))
          (should (= indent (nth 2 (car lines)))))
        ;; The paperclip leads the first line.
        (should (string-match-p (regexp-quote (harness-ui-icon 'harness-icon-attach)) (car (car lines))))
        ;; The deep file keeps where it starts and what it is called.
        (should (string-match-p "src/comp.*…/the-file\\.tsx (4 B) ×\\'" (car (nth 0 lines))))
        (should (string-match-p "notes\\.txt (5 B) ×\\'" (car (nth 1 lines))))
        (should (string-match-p "a-dow.*…" (car (nth 4 lines))))
        (should (string-match-p "connecting" (car (nth 4 lines)))))
      ;; The tooltips tell the whole path and the whole link.
      (save-excursion
        (goto-char (point-min))
        (search-forward "src/comp")
        (should (string-match-p (regexp-quote (abbreviate-file-name deep)) (get-text-property (point) 'help-echo)))
        (should-not (string-match-p "\n" (get-text-property (point) 'help-echo))))
      (should (string-match-p "https://example\\.com/releases/a-download-1\\.2\\.3\\.tar\\.gz\\'"
                              (overlay-get (cdr (assoc "dl" harness-compose--progress)) 'help-echo)))
      ;; In the wide window, every name is whole.
      (set-window-buffer window (current-buffer))
      (delete-window side)
      (harness-compose-redraw)
      (let ((lines (harness-ui-compose-test--attachment-lines window)))
        (should (= 5 (length lines)))
        (cl-loop for (text columns) in lines
                 for name in names
                 do (should (string-search name text))
                 (should-not (string-search "…" (string-replace "connecting…" "" text)))
                 (should (< columns (window-body-width window))))))))

(ert-deftest harness-ui-compose-attachments-fit-again-when-a-window-narrows ()
  "A window showing the box changing size has the host fit the lines again."
  (harness-ui-compose-test-with
    (should (memq #'harness-compose--on-resize window-size-change-functions))
    (let* ((harness-state-directory (file-name-as-directory (expand-file-name "state" dir)))
           (window (selected-window))
           (deep (harness-ui-compose-test--attach-all-kinds dir)))
      (should (string-search harness-ui-compose-test--deep (car (car (harness-ui-compose-test--attachment-lines window)))))
      (let ((draws harness-ui-compose-test--draws)
            (side (split-window window 40 'right)))
        (set-window-buffer side (current-buffer))
        ;; A batch Emacs never redisplays, which would run the hook.
        (harness-compose--on-resize side)
        (harness-test-wait (lambda () (> harness-ui-compose-test--draws draws)) 2 "the lines fitted again")
        ;; Both windows show them: they fit the narrower.
        (dolist (line (harness-ui-compose-test--attachment-lines side))
          (should (< (nth 1 line) (min (window-body-width side) (window-body-width window)))))
        (should-not (string-search harness-ui-compose-test--deep
                                   (car (car (harness-ui-compose-test--attachment-lines side)))))
        (should (string-search (file-name-nondirectory deep)
                               (car (car (harness-ui-compose-test--attachment-lines side)))))
        ;; Fitting them again for the same windows would change nothing:
        ;; the host is left alone.
        (setq draws harness-ui-compose-test--draws)
        (harness-compose--on-resize side)
        (sleep-for 0.4)
        (should (= draws harness-ui-compose-test--draws))))))

(ert-deftest harness-ui-compose-long-names-shorten-in-the-middle ()
  "A name too long keeps its start and its end, a path its file's name."
  (should (equal "notes.txt" (harness-compose--shorten "notes.txt" 9)))
  (should (equal "Screens…-11.png" (harness-compose--shorten "Screenshot from 2026-10-05 14-32-11.png" 15)))
  (should (equal "src/comp…/the-file.tsx" (harness-compose--shorten harness-ui-compose-test--deep 22)))
  ;; A file's name too long to keep whole: its path's start and its end.
  (let ((short (harness-compose--shorten "src/a-name-far-too-long-to-keep-whole.tsx" 20)))
    (should (= 20 (string-width short)))
    (should (string-prefix-p "src/a-na" short))
    (should (string-suffix-p "whole.tsx" short)))
  ;; Wide characters take two columns each.
  (let ((short (harness-compose--shorten "日本語のとても長いファイルの名前.txt" 15)))
    (should (<= (string-width short) 15))
    (should (string-prefix-p "日本語" short))
    (should (string-suffix-p "前.txt" short)))
  ;; Fitted to a width, as long as fits, and never shorter than the least.
  (let ((name "Screenshot from 2026-10-05 14-32-11 with a long name.png"))
    (should (equal name (harness-compose--fit name 80 #'identity)))
    (should (= 30 (string-width (harness-compose--fit name 30 #'identity))))
    (should (= 26 (string-width (harness-compose--fit name 30 (lambda (n) (concat n " ×  "))))))
    (should (= harness-compose--min-name (string-width (harness-compose--fit name 3 #'identity))))))

;;;; The media ring

(ert-deftest harness-ui-compose-media-ring-keeps-captures ()
  (harness-ui-compose-test-with
    (let* ((a (harness-media-ring-save harness-test-png "image/png"))
           (b (harness-media-ring-save (concat harness-test-png "b") "image/png"))
           (clips (expand-file-name "clips/" harness-state-directory)))
      (should (equal (list (plist-get b :path) (plist-get a :path))
                     (mapcar (lambda (e) (plist-get e :path)) (harness-media-ring-entries))))
      (should (string-match-p "\\`clip-[0-9]\\{8\\}-[0-9]\\{6\\}-[0-9a-f]\\{12\\}\\.png\\'" (file-name-nondirectory (plist-get a :path))))
      (should (string-match-p "\\`clip-[0-9]\\{8\\}-[0-9]\\{6\\}\\.png\\'" (plist-get a :name)))
      ;; The same bytes again: the same file, moved to the front.
      (set-file-times (plist-get a :path) (time-subtract nil 100))
      (set-file-times (plist-get b :path) (time-subtract nil 50))
      (should (equal (plist-get a :path) (plist-get (harness-media-ring-save harness-test-png "image/png") :path)))
      (should (= 2 (length (directory-files clips nil "\\`clip-"))))
      (should (equal (plist-get a :path) (plist-get (car (harness-media-ring-entries)) :path)))
      ;; Read back from the directory after a restart, newest first.
      (setq harness-media-ring nil harness-media-ring--loaded nil)
      (let ((entries (harness-media-ring-entries)))
        (should (equal (list (plist-get a :path) (plist-get b :path)) (mapcar (lambda (e) (plist-get e :path)) entries)))
        (should (equal (plist-get a :sha1) (plist-get (car entries) :sha1)))
        (should (equal "image/png" (plist-get (car entries) :mime))))
      ;; It keeps `harness-media-ring-max' entries; the files stay.
      (let ((harness-media-ring-max 2))
        (harness-media-ring-save "<p>hi</p>" "text/html")
        (should (= 2 (length (harness-media-ring-entries))))
        (should (equal "text/html" (plist-get (car (harness-media-ring-entries)) :mime)))
        (should (string-suffix-p ".html" (plist-get (car (harness-media-ring-entries)) :path))))
      (should (= 3 (length (directory-files clips nil "\\`clip-")))))))

(defmacro harness-ui-compose-test-clipboard (selection &rest body)
  "Run BODY on a graphical display whose clipboard holds SELECTION.
SELECTION is an alist of TYPE, a symbol, and its data; the clipboard's
TARGETS are those types.  `kill-ring' holds \"killed text\" and the
clipboard gives no text to the kill ring."
  (declare (indent 1))
  `(let ((selection ,selection)
         (kill-ring (list "killed text"))
         (kill-ring-yank-pointer nil)
         (interprogram-paste-function nil))
     (setq kill-ring-yank-pointer kill-ring)
     (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
               ((symbol-function 'gui-backend-selection-owner-p) (lambda (&rest _) nil))
               ((symbol-function 'gui-get-selection)
                (lambda (_which type)
                  (if (eq type 'TARGETS)
                      (vconcat (cons 'TARGETS (mapcar #'car selection)))
                    (cdr (assq type selection))))))
       ,@body)))

(defun harness-ui-compose-test--command (command &optional arg)
  "Run COMMAND with ARG as the command loop would, after `last-command'.
Point starts after the box, where a command loop's hooks move it from."
  (goto-char (point-max))
  (let ((this-command command)
        (current-prefix-arg arg))
    (call-interactively command)
    (setq last-command this-command)))

(ert-deftest harness-ui-compose-yank-attaches-the-clipboard-image ()
  (harness-ui-compose-test-with
    (let ((last-command nil)
          (older (harness-media-ring-save (concat harness-test-png "older") "image/png")))
      (harness-ui-compose-test-clipboard `((image/png . ,harness-test-png) (text/html . "<img src=x>"))
        (should (eq 'harness-compose-yank (key-binding (kbd "C-y"))))
        (harness-ui-compose-test--command 'harness-compose-yank)
        (should (eq 'harness-compose-yank last-command))
        (let ((att (car harness-compose-attachments)))
          (should (= 1 (length harness-compose-attachments)))
          (should (equal "image/png" (plist-get att :mime)))
          (should (equal harness-test-png (harness-ui-compose-test--bytes (plist-get att :path))))
          (should (equal (plist-get att :path) (plist-get (car (harness-media-ring-entries)) :path)))
          (should (equal "image 1" (plist-get att :label))))
        ;; Its token went into the box, for the text to name it by.
        (should (equal "[image 1] " (harness-compose-text)))
        ;; M-y right after goes back through the ring, and around: the
        ;; capture takes the image's place, token and number.
        (harness-ui-compose-test--command 'harness-compose-yank-pop)
        (should (equal (list (plist-get older :path)) (mapcar (lambda (a) (plist-get a :path)) harness-compose-attachments)))
        (should (equal "image 1" (plist-get (car harness-compose-attachments) :label)))
        (should (equal "[image 1] " (harness-compose-text)))
        (harness-ui-compose-test--command 'harness-compose-yank-pop)
        (should (equal "image/png" (plist-get (car harness-compose-attachments) :mime)))
        (should (equal harness-test-png (harness-ui-compose-test--bytes (plist-get (car harness-compose-attachments) :path))))
        (should (= 1 (length harness-compose-attachments)))
        (should (equal "[image 1] " (harness-compose-text)))
        ;; Yanking again, the image attached already, yanks text.
        (harness-ui-compose-test--command 'harness-compose-yank)
        (should (equal "[image 1] killed text" (harness-compose-text)))
        (should (eq 'yank last-command))
        (should (= 1 (length harness-compose-attachments)))
        ;; `kill-ring' never saw the image.
        (should (equal '("killed text") kill-ring))
        ;; So does C-u C-y, whatever the clipboard holds.
        (harness-compose-set "")
        (setq harness-compose-attachments nil)
        (harness-ui-compose-test--command 'harness-compose-yank '(4))
        (should (equal "killed text" (harness-compose-text)))
        (should-not harness-compose-attachments)))))

(ert-deftest harness-ui-compose-yank-yanks-text-when-the-clipboard-is-text ()
  (harness-ui-compose-test-with
    (let ((last-command nil))
      ;; LibreOffice cells come with a picture of them: they are text.
      (harness-ui-compose-test-clipboard `((application/x-libreoffice-tsvc . "a\tb") (image/png . ,harness-test-png)
                                           (UTF8_STRING . "a\tb"))
        (harness-ui-compose-test--command 'harness-compose-yank)
        (should-not harness-compose-attachments)
        (should (equal "killed text" (harness-compose-text))))
      ;; What this Emacs put on the clipboard is the newest kill.
      (harness-compose-set "")
      (harness-ui-compose-test-clipboard `((image/png . ,harness-test-png))
        (cl-letf (((symbol-function 'gui-backend-selection-owner-p) (lambda (&rest _) t)))
          (harness-ui-compose-test--command 'harness-compose-yank))
        (should-not harness-compose-attachments)
        (should (equal "killed text" (harness-compose-text))))
      ;; Off, the box leaves C-y and M-y alone, remapping included.
      (let ((harness-compose-yank-media nil))
        (should (eq 'yank (key-binding (kbd "C-y"))))
        (should (eq 'yank-pop (key-binding (kbd "M-y")))))
      ;; M-y after a yank of text runs what M-y runs elsewhere, a remap
      ;; (`consult-yank-pop' in Doom, say) included.
      (let ((ran nil))
        (defalias 'harness-ui-compose-test--other-yank-pop (lambda () (interactive) (setq ran t)))
        (unwind-protect
            (progn
              (define-key global-map [remap yank-pop] #'harness-ui-compose-test--other-yank-pop)
              (should (eq 'harness-compose-yank-pop (key-binding (kbd "M-y"))))
              (harness-ui-compose-test--command 'harness-compose-yank-pop)
              (should ran))
          (define-key global-map [remap yank-pop] nil))))))

(ert-deftest harness-ui-compose-yank-attaches-copied-files ()
  (harness-ui-compose-test-with
    (let ((last-command nil)
          (one (expand-file-name "one pic.png" dir))
          (two (expand-file-name "two.txt" dir)))
      (with-temp-file one (insert "1"))
      (with-temp-file two (insert "2"))
      (harness-ui-compose-test-clipboard `((text/uri-list . ,(concat "file://" (string-replace " " "%20" one) "\r\nfile://" two "\r\n"))
                                           (UTF8_STRING . ,(concat one "\n" two)))
        (harness-ui-compose-test--command 'harness-compose-yank)
        (should (equal (list one two) (mapcar (lambda (a) (plist-get a :path)) harness-compose-attachments)))
        (should (equal '("image/png" "text/plain") (mapcar (lambda (a) (plist-get a :mime)) harness-compose-attachments)))
        ;; Each has its token in the text: the image its label, the
        ;; other file its @ reference.
        (should (equal '("image 1" nil) (mapcar (lambda (a) (plist-get a :label)) harness-compose-attachments)))
        (should (equal '(nil "two.txt") (mapcar (lambda (a) (plist-get a :ref)) harness-compose-attachments)))
        (should (equal "[image 1] @two.txt " (harness-compose-text)))
        ;; Files copied are no captures: the ring stays empty.
        (should-not (harness-media-ring-entries))
        (harness-ui-compose-test--command 'harness-compose-yank)
        (should (equal "[image 1] @two.txt killed text" (harness-compose-text))))
      ;; A copied web link is text.
      (harness-compose-set "")
      (setq harness-compose-attachments nil)
      (harness-ui-compose-test-clipboard '((text/uri-list . "https://example.com/a.png\r\n"))
        (harness-ui-compose-test--command 'harness-compose-yank)
        (should-not harness-compose-attachments)
        (should (equal "killed text" (harness-compose-text)))))))

(ert-deftest harness-ui-compose-attach-clipboard-and-the-ring ()
  (harness-ui-compose-test-with
    (harness-ui-compose-test-clipboard `((image/png . ,harness-test-png))
      (harness-ui-compose-test--command 'harness-compose-attach-clipboard)
      (should (equal "image/png" (plist-get (car harness-compose-attachments) :mime)))
      (should (= 1 (length (harness-media-ring-entries)))))
    ;; Other types are chosen from, then captured.
    (setq harness-compose-attachments nil)
    (harness-ui-compose-test-clipboard '((text/html . "<b>bold</b>") (UTF8_STRING . "bold"))
      (cl-letf (((symbol-function 'completing-read) (lambda (_prompt choices &rest _) (car (all-completions "" choices)))))
        (harness-ui-compose-test--command 'harness-compose-attach-clipboard)))
    (let ((att (car harness-compose-attachments)))
      (should (equal "text/html" (plist-get att :mime)))
      (should (string-suffix-p ".html" (plist-get att :path)))
      (should (equal "<b>bold</b>" (harness-ui-compose-test--bytes (plist-get att :path)))))
    (should (= 2 (length (harness-media-ring-entries))))
    ;; C-u M-x harness-compose-attach-clipboard attaches an earlier capture.
    (setq harness-compose-attachments nil)
    (let ((png (cl-find "image/png" (harness-media-ring-entries) :key (lambda (e) (plist-get e :mime)) :test #'equal)))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (cl-find-if (lambda (c) (string-prefix-p (plist-get png :name) c)) (all-completions "" table)))))
        (harness-ui-compose-test--command 'harness-compose-attach-clipboard '(4)))
      (should (equal (list (plist-get png :path)) (mapcar (lambda (a) (plist-get a :path)) harness-compose-attachments))))
    ;; `yank-media' finds the box's handler.
    (setq harness-compose-attachments nil)
    (harness-compose--yank-media-image 'image/png harness-test-png)
    (should (equal "image/png" (plist-get (car harness-compose-attachments) :mime)))))

(ert-deftest harness-ui-compose-c-c-c-v-is-not-the-boxes ()
  "C-c C-v is not the box's key: pasting is C-y, and Verify keeps C-c C-v.
The box leaves C-c C-v unbound, so in a chat the review banner's
[Verify] owns it and nothing shadows it."
  (harness-ui-compose-test-with
    (should-not (lookup-key harness-compose-map (kbd "C-c C-v")))
    (should-not (key-binding (kbd "C-c C-v")))
    ;; Every key that yanks pastes into the box.
    (should (eq 'harness-compose-yank (key-binding (kbd "C-y"))))
    (should (eq 'harness-compose-yank-pop (key-binding (kbd "M-y"))))))

;;;; Image tokens

(defmacro harness-ui-compose-test--attaching (path &rest body)
  "Run BODY with the attach command reading PATH, a variable, for its file."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'harness-compose-read-file) (lambda (&rest _) ,path)))
     ,@body))

(defun harness-ui-compose-test--labels ()
  "Return the labels of the attachments, nil for one without."
  (mapcar (lambda (a) (plist-get a :label)) harness-compose-attachments))

(ert-deftest harness-ui-compose-image-tokens-go-where-point-is ()
  "An image attached puts its token where point is in the box, else at its end.
The token keeps apart from the words around it and point goes on after
it.  The image's line in the list leads with the token, its prompt
block carries its label, and the token shows as a chip.  A file that is
no image and whose name can be no @ reference, a space in it, gets no
token."
  (harness-ui-compose-test-with
    (let ((a (plist-get (harness-media-ring-save harness-test-png "image/png") :path))
          (b (plist-get (harness-media-ring-save (concat harness-test-png "b") "image/png") :path))
          (notes (expand-file-name "my notes.txt" dir)))
      (with-temp-file notes (insert "notes"))
      (harness-compose-set "compare with")
      (goto-char (+ harness-compose-start (length "compare ")))
      (harness-compose-add-attachment a)
      (should (equal "compare [image 1] with" (harness-compose-text)))
      (should (= (point) (+ harness-compose-start (length "compare [image 1] "))))
      ;; Point out of the box: the end of the box.
      (goto-char (point-min))
      (harness-compose-add-attachment b)
      (harness-compose-add-attachment notes)
      (should (equal "compare [image 1] with [image 2] " (harness-compose-text)))
      (should (equal '("image 1" "image 2" nil) (harness-ui-compose-test--labels)))
      ;; The list names each image by its token.
      (save-excursion
        (goto-char (point-min))
        (should (search-forward "[image 1] clip-" harness-compose-start t))
        (should (search-forward "[image 2] clip-" harness-compose-start t))
        (should-not (search-forward "[image" harness-compose-start t)))
      ;; The model gets the label with the image.
      (should (equal '(:label "image 2") (plist-get (harness-compose-attachment-block (nth 1 harness-compose-attachments))
                                                   :_harness)))
      (should-not (plist-member (harness-compose-attachment-block (nth 2 harness-compose-attachments)) :_harness))
      ;; Each token is a chip over its text, which point steps over whole.
      (let ((ov (car harness-compose--token-overlays)))
        (should (equal '("image 1" "image 2")
                       (mapcar (lambda (o) (overlay-get o 'harness-compose-label)) harness-compose--token-overlays)))
        (should (equal "[image 1]" (buffer-substring-no-properties (overlay-start ov) (overlay-end ov))))
        (should (equal "[image 1]" (substring-no-properties (overlay-get ov 'display))))
        (should (string-match-p "mouse-1: open" (overlay-get ov 'help-echo))))
      ;; The numbers go on from the highest attached.
      (harness-compose-remove-attachment a)
      (should (equal "compare with [image 2] " (harness-compose-text)))
      (should (equal '("image 2" nil) (harness-ui-compose-test--labels)))
      (harness-compose-add-attachment a)
      (should (equal '("image 2" nil "image 3") (harness-ui-compose-test--labels)))
      (should (equal "compare with [image 2] [image 3] " (harness-compose-text)))
      ;; A new message starts again at 1.
      (harness-compose-clear)
      (harness-compose-add-attachment b)
      (should (equal "[image 1] " (harness-compose-text)))
      (should (equal '("image 1") (harness-ui-compose-test--labels))))))

(ert-deftest harness-ui-compose-image-tokens-and-attachments-agree ()
  "After every command the box's tokens and its images agree.
DEL right after a token deletes it whole and removes its image, and
undo brings both back; a token killed and yanked, or typed, back brings
its image back; the × of an image's line takes its token too.  The keys
go through the command loop."
  (harness-ui-compose-test-with
    (let ((a (plist-get (harness-media-ring-save harness-test-png "image/png") :path))
          (b (plist-get (harness-media-ring-save (concat harness-test-png "b") "image/png") :path))
          (kill-ring nil) (kill-ring-yank-pointer nil)
          (interprogram-cut-function nil) (interprogram-paste-function nil))
      (goto-char harness-compose-end)
      (execute-kbd-macro "see ")
      (harness-ui-compose-test--attaching a (execute-kbd-macro (kbd "C-c C-a")))
      (execute-kbd-macro "and ")
      (harness-ui-compose-test--attaching b (execute-kbd-macro (kbd "C-c C-a")))
      (should (equal "see [image 1] and [image 2] " (harness-compose-text)))
      ;; Point never rests inside a token.
      (goto-char (+ harness-compose-start (length "see [image 1] and ")))
      (execute-kbd-macro (kbd "C-f"))
      (should (= (point) (+ harness-compose-start (length "see [image 1] and [image 2]"))))
      ;; DEL right after a token deletes the whole of it, and its image.
      (goto-char (+ harness-compose-start (length "see [image 1]")))
      (execute-kbd-macro (kbd "DEL"))
      (should (equal "see  and [image 2] " (harness-compose-text)))
      (should (equal '("image 2") (harness-ui-compose-test--labels)))
      (save-excursion (goto-char (point-min)) (should-not (search-forward "[image 1]" harness-compose-start t)))
      ;; Undo brings both back, the image in its place in the list.
      (execute-kbd-macro (kbd "C-/"))
      (should (equal "see [image 1] and [image 2] " (harness-compose-text)))
      (should (equal (list a b) (mapcar (lambda (x) (plist-get x :path)) harness-compose-attachments)))
      (should (equal '("image 1" "image 2") (harness-ui-compose-test--labels)))
      (should (equal "The transcript.\n" (harness-ui-compose-test--transcript)))
      ;; Killed, the tokens take their images along; yanked, back they come.
      (goto-char harness-compose-end)
      (execute-kbd-macro (kbd "C-a C-k"))
      (should (equal "" (harness-compose-text)))
      (should-not harness-compose-attachments)
      (execute-kbd-macro (kbd "C-y"))
      (should (equal "see [image 1] and [image 2] " (harness-compose-text)))
      (should (equal '("image 1" "image 2") (harness-ui-compose-test--labels)))
      ;; The × of an image's line removes its token too, and typing the
      ;; token back brings the image back.
      (harness-compose-remove-attachment a)
      (should (equal "see and [image 2] " (harness-compose-text)))
      (should (equal '("image 2") (harness-ui-compose-test--labels)))
      (goto-char harness-compose-end)
      (execute-kbd-macro "[image 1]")
      (should (equal '("image 1" "image 2") (harness-ui-compose-test--labels)))
      ;; What is sent: the text with its tokens, the images with labels.
      (pcase-let ((`(,text . ,atts) (harness-compose-take)))
        (should (equal "see and [image 2] [image 1]" text))
        (should (equal '("image 1" "image 2") (mapcar (lambda (x) (plist-get x :label)) atts))))
      ;; Images attached without a label (a draft from before) are left alone.
      (harness-compose-clear)
      (setq harness-compose-attachments (list (harness-compose--file-attachment a)))
      (execute-kbd-macro "x")
      (should (equal (list a) (mapcar (lambda (x) (plist-get x :path)) harness-compose-attachments))))))

(ert-deftest harness-ui-compose-undo-follows-the-box ()
  "Undo changes the box's text even after the host drew more above it.
The host draws with undo off, so what it draws above the box moves the
box's text but not the undo entries: they move with the box, and undo
never reaches the read-only text."
  (harness-ui-compose-test-with
    ;; A space in its name: the file attaches with no reference in the text.
    (let ((notes (expand-file-name "my notes.txt" dir)))
      (with-temp-file notes (insert "notes"))
      (goto-char harness-compose-end)
      (execute-kbd-macro "hello")
      ;; A line drawn above the box, as attaching a file draws one.
      (harness-compose-add-attachment notes)
      (should (equal "hello" (harness-compose-text)))
      (goto-char harness-compose-end)
      ;; C-e first, so the typing is an undo step of its own.
      (execute-kbd-macro (kbd "C-e SPC t h e r e"))
      (should (equal "hello there" (harness-compose-text)))
      (harness-compose-remove-attachment notes)
      (execute-kbd-macro (kbd "C-/"))
      (should (equal "hello" (harness-compose-text)))
      (should (equal "The transcript.\n" (harness-ui-compose-test--transcript))))))

;;;; Finding files

(defmacro harness-ui-compose-test--files (&rest body)
  "Run BODY in a project with files, a directory next to it and a home.
`proj' is the box's project, listing notes.txt and lisp/notes-util.el;
`other' is the directory next to it, with notes.md and deep/x.txt;
`home' is $HOME, with doc.txt.  All three are directory names."
  (declare (indent 0))
  `(let* ((proj (file-name-as-directory (expand-file-name "proj" dir)))
          (other (file-name-as-directory (expand-file-name "other" dir)))
          (home (file-name-as-directory (expand-file-name "home" dir)))
          (process-environment (cons (concat "HOME=" (directory-file-name home)) process-environment)))
     (dolist (file (list (expand-file-name "notes.txt" proj) (expand-file-name "lisp/notes-util.el" proj)
                         (expand-file-name "notes.md" other) (expand-file-name "deep/x.txt" other)
                         (expand-file-name "doc.txt" home)))
       (make-directory (file-name-directory file) t)
       (with-temp-file file (insert "x")))
     (setq harness-compose-project-function (lambda () proj)
           harness-compose--files '("notes.txt" "lisp/notes-util.el"))
     (cl-letf (((symbol-function 'harness-files-list-limited)
                (lambda (&rest _) (harness-resolved '("notes.txt" "lisp/notes-util.el")))))
       ,@body)))

(defmacro harness-ui-compose-test--never-remote (&rest body)
  "Run BODY, failing if it hands a remote file name to a file name handler.
A handler for /ssh: names records each operation; BODY's value is
returned once none was."
  (declare (indent 0))
  `(let* ((asked nil)
          (file-name-handler-alist
           (cons (cons "\\`/ssh:" (lambda (operation &rest _) (push operation asked) (error "Remote file reached")))
                 file-name-handler-alist)))
     (prog1 (progn ,@body)
       (should-not asked))))

(defun harness-ui-compose-test--matches (input table)
  "Return the candidates of TABLE that INPUT completes to, sorted, without properties."
  (let ((all (completion-all-completions input table nil (length input))))
    (when (consp all) (setcdr (last all) nil))
    (sort (mapcar #'substring-no-properties all) #'string<)))

(defun harness-ui-compose-test--category (input table)
  "Return the completion category TABLE gives INPUT."
  (completion-metadata-get (completion-metadata input table nil) 'category))

(defun harness-ui-compose-test--paths ()
  "Return the paths of the box's attachments."
  (mapcar (lambda (a) (plist-get a :path)) harness-compose-attachments))

(defun harness-ui-compose-test--complete (capf string status)
  "Complete the token of CAPF to STRING, as a completion UI does, and exit with STATUS."
  (delete-region (nth 0 capf) (nth 1 capf))
  (goto-char (nth 0 capf))
  (insert string)
  (funcall (plist-get (nthcdr 3 capf) :exit-function) string status))

(ert-deftest harness-ui-compose-finds-files-by-name-or-by-path ()
  ;; Part of a name finds a project file; a path finds any file:
  ;; absolute, under ~, or relative to the project with ./ or ../,
  ;; reaching out of it.  Paths complete a directory at a time, in the
  ;; file category.  A remote name completes to nothing, without its
  ;; handler (TRAMP's) ever being asked.
  (harness-ui-compose-test-with
    (harness-ui-compose-test--files
      (dolist (name '("notes" ".gitignore" "lisp/notes-util.el" "skill:review" ".x"))
        (should-not (harness-compose--path-p name)))
      (dolist (path '("/etc/hosts" "~" "~/doc.txt" "./notes.txt" "../other/" ".."))
        (should (harness-compose--path-p path)))
      (let ((table (harness-compose--file-table)))
        (should (eq 'harness-compose-file (harness-ui-compose-test--category "" table)))
        (should (equal '("lisp/notes-util.el" "notes.txt") (harness-ui-compose-test--matches "nots" table)))
        (dolist (path '("../" "~/" "/" "./"))
          (should (eq 'file (harness-ui-compose-test--category path table))))
        (should (equal '("other/") (harness-ui-compose-test--matches "../oth" table)))
        (should (equal '("deep/" "notes.md") (harness-ui-compose-test--matches "../other/" table)))
        (should (equal '(9 . 0) (completion-boundaries "../other/n" table nil "")))
        (should (equal '("doc.txt") (harness-ui-compose-test--matches "~/do" table)))
        (should (equal '("notes.md") (harness-ui-compose-test--matches (concat other "no") table)))
        (should (equal '("notes.txt") (harness-ui-compose-test--matches "./notes" table)))
        (should (member "../" (all-completions ".." table)))
        (should (test-completion "../other/notes.md" table))
        (should-not (test-completion "../other/nope.md" table))
        (harness-ui-compose-test--never-remote
          (should-not (all-completions "/ssh:nohost:/" table))
          (should-not (try-completion "/ssh:nohost:/et" table))
          (should-not (test-completion "/ssh:nohost:/etc/hosts" table)))))))

(ert-deftest harness-ui-compose-at-completes-paths-out-of-the-project ()
  ;; @ completes a path as well as part of a project file's name, and
  ;; the file chosen becomes an attachment as a project file does, the
  ;; token staying in the text as its reference, a chip.  A directory
  ;; stays in the box, for its files to complete next, and so does a
  ;; completion that may go on.
  (harness-ui-compose-test-with
    (harness-ui-compose-test--files
      (goto-char harness-compose-end)
      (insert "compare @../other/")
      (let ((capf (harness-compose-completion-at-point)))
        (should (equal "../other/" (buffer-substring (nth 0 capf) (nth 1 capf))))
        (should (equal '("deep/" "notes.md") (harness-ui-compose-test--matches "../other/" (nth 2 capf))))
        (should (eq 'folder (funcall (plist-get (nthcdr 3 capf) :company-kind) "deep/")))
        (should (eq 'file (funcall (plist-get (nthcdr 3 capf) :company-kind) "notes.md")))
        (harness-ui-compose-test--complete capf "../other/deep/" 'finished))
      (should (equal "compare @../other/deep/" (harness-compose-text)))
      (should-not harness-compose-attachments)
      (let ((capf (harness-compose-completion-at-point)))
        (should (equal '("x.txt") (harness-ui-compose-test--matches "../other/deep/" (nth 2 capf))))
        (harness-ui-compose-test--complete capf "../other/deep/x.txt" 'finished))
      ;; The token stays, as typed, a space after it to type on.
      (should (equal "compare @../other/deep/x.txt " (harness-compose-text)))
      (should (= (point) harness-compose-end))
      (should (equal (list (expand-file-name "deep/x.txt" other)) (harness-ui-compose-test--paths)))
      (should (equal "../other/deep/x.txt" (plist-get (car harness-compose-attachments) :ref)))
      (harness-compose--sync-tokens)
      (should (equal '("@../other/deep/x.txt")
                     (mapcar (lambda (o) (buffer-substring-no-properties (overlay-start o) (overlay-end o)))
                             harness-compose--token-overlays)))
      ;; Under ~: exact, it could go on, so it waits; sole, it attaches.
      (insert "with @~/do")
      (let ((capf (harness-compose-completion-at-point)))
        (should (equal '("doc.txt") (harness-ui-compose-test--matches "~/do" (nth 2 capf))))
        (harness-ui-compose-test--complete capf "~/doc.txt" 'exact))
      (should (equal "compare @../other/deep/x.txt with @~/doc.txt" (harness-compose-text)))
      (should (= 1 (length harness-compose-attachments)))
      (funcall (plist-get (nthcdr 3 (harness-compose-completion-at-point)) :exit-function) "~/doc.txt" 'sole)
      (should (equal "compare @../other/deep/x.txt with @~/doc.txt " (harness-compose-text)))
      ;; Absolute, and a project file as before.
      (insert (concat "@" other "no"))
      (harness-ui-compose-test--complete (harness-compose-completion-at-point) (concat other "notes.md") 'finished)
      (insert "@nots")
      (let ((capf (harness-compose-completion-at-point)))
        (should (equal '("lisp/notes-util.el" "notes.txt") (harness-ui-compose-test--matches "nots" (nth 2 capf))))
        (harness-ui-compose-test--complete capf "notes.txt" 'finished))
      (should (equal (concat "compare @../other/deep/x.txt with @~/doc.txt @" other "notes.md @notes.txt ")
                     (harness-compose-text)))
      (should (equal (list (expand-file-name "deep/x.txt" other) (expand-file-name "doc.txt" home)
                           (expand-file-name "notes.md" other) (expand-file-name "notes.txt" proj))
                     (harness-ui-compose-test--paths)))
      ;; Sent, the text keeps the references and each file goes once.
      (pcase-let ((`(,text . ,atts) (harness-compose-take)))
        (should (string-suffix-p "@notes.txt" text))
        (should (equal (harness-ui-compose-test--paths) (mapcar (lambda (a) (plist-get a :path)) atts)))))))

(ert-deftest harness-ui-compose-attach-command-takes-paths ()
  ;; C-c C-a reads a path as well as part of a project file's name,
  ;; with no C-u: out of the project, under ~ or absolute.  A leading @,
  ;; typed out of the box's habit, is ignored.
  (harness-ui-compose-test-with
    (harness-ui-compose-test--files
      (let ((table nil) (answer nil))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt collection &rest _) (setq table collection) answer))
                  ((symbol-function 'read-file-name) (lambda (&rest _) (error "Browsed"))))
          (pcase-dolist (`(,typed . ,file)
                         `(("../other/notes.md" . ,(expand-file-name "notes.md" other))
                           ("~/doc.txt" . ,(expand-file-name "doc.txt" home))
                           (,(expand-file-name "deep/x.txt" other) . ,(expand-file-name "deep/x.txt" other))
                           ("lisp/notes-util.el" . ,(expand-file-name "lisp/notes-util.el" proj))
                           ("@notes.txt" . ,(expand-file-name "notes.txt" proj))
                           ("@../other/notes.md" . ,(expand-file-name "notes.md" other))))
            (setq harness-compose-attachments nil answer typed)
            (harness-ui-compose-test--command 'harness-compose-add-attachment)
            (should (equal (list file) (harness-ui-compose-test--paths)))))
        ;; The prompt's table: past a leading @, names and paths complete as in the box.
        (should (eq 'harness-compose-file (harness-ui-compose-test--category "@" table)))
        (should (eq 'file (harness-ui-compose-test--category "@../" table)))
        (should (equal '("lisp/notes-util.el" "notes.txt") (harness-ui-compose-test--matches "@nots" table)))
        (should (equal '("other/") (harness-ui-compose-test--matches "@../oth" table)))
        (should (equal '(4 . 0) (completion-boundaries "@../oth" table nil "")))
        (should (equal '(1 . 0) (completion-boundaries "@nots" table nil "")))
        (should (equal "@../other/notes.md" (try-completion "@../other/no" table)))
        (should (test-completion "@../other/notes.md" table))
        (should (test-completion "@notes.txt" table))
        (should-not (test-completion "@nope.txt" table))))))

(ert-deftest harness-ui-compose-attach-command-opens-directories ()
  ;; A directory is no file to attach, and neither is nothing: the
  ;; prompt comes back, from inside the directory chosen.
  (harness-ui-compose-test-with
    (harness-ui-compose-test--files
      (let ((answers '("" "@../other/" "../other/deep" "../other/deep/x.txt"))
            (initials nil))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt _collection _pred _require initial &rest _)
                     (push initial initials)
                     (pop answers))))
          (harness-ui-compose-test--command 'harness-compose-add-attachment))
        (should (equal '(nil nil "../other/" "../other/deep/") (nreverse initials)))
        (should (equal (list (expand-file-name "deep/x.txt" other)) (harness-ui-compose-test--paths)))))))

(ert-deftest harness-ui-compose-typed-references-attach-when-taken ()
  ;; An @ reference typed out in full, or pasted, attaches its file when
  ;; the message is taken, as one completed does, and stays in the text:
  ;; a project file, a path out of the project, under ~ or absolute.
  ;; Punctuation after it is no part of it.  @skill: references, a
  ;; missing file, a directory, an @ inside a word and a remote name
  ;; attach nothing, and a file is attached once.
  (harness-ui-compose-test-with
    (harness-ui-compose-test--files
      (harness-compose-add-attachment (expand-file-name "notes.txt" proj))
      (let ((text (format "compare @notes.txt with @../other/notes.md, @~/doc.txt and (see @%s).
@skill:review @missing.txt @../other/deep/ @/ssh:nohost:/etc/hosts mail@example.com
@lisp/notes-util.el @../other/notes.md"
                          (expand-file-name "deep/x.txt" other))))
        (harness-compose-set text)
        (pcase-let ((`(,sent . ,atts) (harness-ui-compose-test--never-remote (harness-compose-take))))
          (should (equal text sent))
          (should (equal (list (expand-file-name "notes.txt" proj) (expand-file-name "notes.md" other)
                               (expand-file-name "doc.txt" home) (expand-file-name "deep/x.txt" other)
                               (expand-file-name "lisp/notes-util.el" proj))
                         (mapcar (lambda (a) (plist-get a :path)) atts)))
          (should (equal '("notes.txt" "notes.md" "doc.txt" "x.txt" "notes-util.el")
                         (mapcar (lambda (a) (plist-get a :name)) atts)))
          (should (equal "text/plain" (plist-get (nth 2 atts) :mime))))
        ;; The box is left as it was: its host clears it once sent.
        (should (equal (list (expand-file-name "notes.txt" proj)) (harness-ui-compose-test--paths)))
        (should (equal text (harness-compose-text))))
      ;; References alone are a message.
      (harness-compose-clear)
      (harness-compose-set "@~/doc.txt")
      (should (equal (list "@~/doc.txt" (expand-file-name "doc.txt" home))
                     (pcase (harness-compose-take) (`(,sent ,att) (list sent (plist-get att :path)))))))))

;;;; Finding files in a task's worktree and the main checkout

(defmacro harness-ui-compose-test--workspaces (&rest body)
  "Run BODY in a box with two roots, as a chat in a task's worktree has.
`main' is the box's project, the main checkout, and `wt' the task's
worktree, in a directory of its own below it as the harness makes them;
both are out of the state directory, whose files the chips name alone.
Both hold shared.txt and lisp/shared.el, their own copies; only `wt'
holds lisp/task-only.el and lisp/new.el, only `main' main-only.md and
docs/guide.md.  Listing a root answers with the files it holds, as
`harness-files-list-limited' does -- the main checkout's with the
worktree nested in it, as git lists a nested worktree -- through the
promise or the list `listings' has for it: an alist, root -> files.
`answer' is what the prompt of the attach command is answered, when
it is asked, and `asked' the table it was asked with."
  (declare (indent 0))
  `(let* ((parent (harness-test-temp-dir))
          (main (file-name-as-directory (expand-file-name "main" parent)))
          (wt (file-name-as-directory (expand-file-name ".worktrees/task-1" main)))
          (answer nil) (asked nil)
          (listings nil))
     (unwind-protect
         (progn
           (dolist (spec `((,main "shared.txt" "lisp/shared.el" "main-only.md" "docs/guide.md")
                           (,wt "shared.txt" "lisp/shared.el" "lisp/task-only.el" "lisp/new.el")))
             (dolist (file (cdr spec))
               (let ((path (expand-file-name file (car spec))))
                 (make-directory (file-name-directory path) t)
                 (with-temp-file path (insert (car spec) file)))))
           (setq listings
                 (list (cons wt (list "shared.txt" "lisp/task-only.el" "lisp/shared.el" "lisp/new.el"))
                       (cons main (list "shared.txt" "main-only.md" "docs/guide.md" "lisp/shared.el"
                                        ".worktrees/task-1/")))
                 harness-compose-project-function (lambda () main)
                 harness-compose-roots-function (lambda () (list (cons wt "task") (cons main "main")))
                 harness-compose--files nil)
           (cl-letf (((symbol-function 'harness-files-list-limited)
                      (lambda (root &rest _)
                        (let ((files (cdr (assoc (file-name-as-directory root) listings))))
                          (if (harness-promise-p files) files (harness-resolved files)))))
                     ((symbol-function 'harness-compose-fetch-tasks) #'ignore)
                     ((symbol-function 'completing-read)
                      (lambda (_prompt table &rest _) (setq asked table) answer))
                     ((symbol-function 'read-file-name) (lambda (&rest _) (error "Browsed"))))
             ,@body))
       (ignore-errors (delete-directory parent t)))))

(defun harness-ui-compose-test--annotations (table names)
  "Return what TABLE, a table of files, annotates each of NAMES with."
  (let ((annotate (completion-metadata-get (completion-metadata "" table nil) 'annotation-function)))
    (mapcar (lambda (name) (and annotate (funcall annotate name))) names)))

(ert-deftest harness-ui-compose-attach-lists-the-files-of-both-workspaces ()
  "The attach command offers the union of the files of the task's worktree
and of the main checkout, a file in both once, each marked with where it
is.  A directory the main checkout lists, the nested worktree itself, is
no file to attach."
  (harness-ui-compose-test-with
    (harness-ui-compose-test--workspaces
      (setq answer "shared.txt")
      (harness-ui-compose-test--command 'harness-compose-add-attachment)
      (let* ((all '("shared.txt" "lisp/task-only.el" "lisp/shared.el" "lisp/new.el" "main-only.md" "docs/guide.md"))
             (offered (all-completions "" asked)))
        ;; Every file, the worktree's first, each once.
        (should (equal all harness-compose--files))
        (should (equal (sort (copy-sequence all) #'string<) (sort (copy-sequence offered) #'string<)))
        (should (equal (list main wt) (sort (mapcar #'car harness-compose--root-files) #'string<)))
        (should-not (member ".worktrees/task-1/" offered))
        (should (eq 'harness-compose-file (harness-ui-compose-test--category "" asked)))
        ;; A file says where it is: in the worktree, the main checkout, or both.
        (should (equal '("  [task, main]" "  [task]" "  [task, main]" "  [task]" "  [main]" "  [main]")
                       (harness-ui-compose-test--annotations asked all)))
        (should-not (car (harness-ui-compose-test--annotations asked '("nope.txt"))))
        ;; Part of a name finds a file of either, as it does a project's.
        (should (equal '("lisp/task-only.el") (harness-ui-compose-test--matches "tonly" asked)))
        (should (equal '("docs/guide.md") (harness-ui-compose-test--matches "guide" asked)))
        (should (equal '("lisp/new.el" "lisp/shared.el" "lisp/task-only.el")
                       (harness-ui-compose-test--matches "lisp/" asked)))
        ;; Past a leading @, as the box takes it.
        (should (equal '("main-only.md") (harness-ui-compose-test--matches "@main" asked)))
        (should (equal '(1 . 0) (completion-boundaries "@main" asked nil ""))))
      ;; Paths complete as they did, relative to the project.
      (should (eq 'file (harness-ui-compose-test--category "./" asked)))
      (should (equal '("main-only.md") (harness-ui-compose-test--matches "./main-o" asked))))))

(ert-deftest harness-ui-compose-attach-reads-a-file-from-the-root-that-has-it ()
  "The file chosen is attached from the root it was listed in: a file only
the worktree has from the worktree, one only the main checkout has from
the main checkout, and one both have, offered once, from the worktree.
Each is the reference in the text and the chip names it from the root it
is in, not by the worktree's place below the project."
  (harness-ui-compose-test-with
    (harness-ui-compose-test--workspaces
      (pcase-dolist (`(,typed ,root ,name ,token)
                     `(("shared.txt" ,wt "shared.txt" "@shared.txt")
                       ("lisp/shared.el" ,wt "shared.el" "@lisp/shared.el")
                       ("lisp/task-only.el" ,wt "task-only.el" "@lisp/task-only.el")
                       ("@lisp/new.el" ,wt "new.el" "@lisp/new.el")
                       ("main-only.md" ,main "main-only.md" "@main-only.md")
                       ("docs/guide.md" ,main "guide.md" "@docs/guide.md")))
        (harness-compose-clear)
        (setq harness-compose-attachments nil answer typed)
        (harness-ui-compose-test--command 'harness-compose-add-attachment)
        (let ((path (expand-file-name (string-remove-prefix "@" typed) root)))
          (should (equal (list path) (harness-ui-compose-test--paths)))
          (should (equal name (plist-get (car harness-compose-attachments) :name)))
          ;; The copy attached is the file of that root.
          (should (equal (concat root (string-remove-prefix "@" typed))
                         (with-temp-buffer (insert-file-contents path) (buffer-string))))
          (should (equal (concat token " ") (harness-compose-text)))
          (should (equal (string-remove-prefix "@" typed)
                         (harness-compose--chip-name (car harness-compose-attachments))))))
      ;; The main checkout's copy of a file the worktree has is no
      ;; reference's: @shared.txt names the worktree's.
      (harness-compose-clear)
      (setq harness-compose-attachments nil)
      (harness-compose-add-attachment (expand-file-name "shared.txt" main))
      (should (equal (list (expand-file-name "shared.txt" main)) (harness-ui-compose-test--paths)))
      (should (equal "" (harness-compose-text)))
      (should (equal "shared.txt" (harness-compose--chip-name (car harness-compose-attachments))))
      ;; A file of the worktree attached some other way goes by its name in it.
      (harness-compose-clear)
      (setq harness-compose-attachments nil)
      (harness-compose-add-attachment (expand-file-name "lisp/new.el" wt))
      (should (equal "@lisp/new.el " (harness-compose-text)))
      (should (equal "lisp/new.el" (harness-compose--chip-name (car harness-compose-attachments)))))))

(ert-deftest harness-ui-compose-at-completes-files-of-both-workspaces ()
  "@ completes the same union, labelled, and a file completed is attached
from the root that holds it.  A reference typed out in full, or pasted,
names the same file, also one the listing has not reached yet."
  (harness-ui-compose-test-with
    (harness-ui-compose-test--workspaces
      (goto-char harness-compose-end)
      (insert "compare @main-")
      (let ((capf (harness-compose-completion-at-point)))
        (should (equal "main-" (buffer-substring (nth 0 capf) (nth 1 capf))))
        (should (equal '("main-only.md") (harness-ui-compose-test--matches "main-" (nth 2 capf))))
        (should (equal '("  [main]") (harness-ui-compose-test--annotations (nth 2 capf) '("main-only.md"))))
        (harness-ui-compose-test--complete capf "main-only.md" 'finished))
      (insert "and @shar")
      (let ((capf (harness-compose-completion-at-point)))
        (should (equal '("lisp/shared.el" "shared.txt") (harness-ui-compose-test--matches "shar" (nth 2 capf))))
        (harness-ui-compose-test--complete capf "shared.txt" 'finished))
      (insert "and @lisp/task")
      (harness-ui-compose-test--complete (harness-compose-completion-at-point) "lisp/task-only.el" 'finished)
      (should (equal "compare @main-only.md and @shared.txt and @lisp/task-only.el " (harness-compose-text)))
      (should (equal (list (expand-file-name "main-only.md" main) (expand-file-name "shared.txt" wt)
                           (expand-file-name "lisp/task-only.el" wt))
                     (harness-ui-compose-test--paths)))
      ;; Typed out in full: the worktree's copy of a file both have.
      (harness-compose-clear)
      (setq harness-compose-attachments nil)
      (harness-compose-set "see @lisp/shared.el, @docs/guide.md and @lisp/new.el.")
      (pcase-let ((`(,text . ,atts) (harness-compose-take)))
        (should (equal "see @lisp/shared.el, @docs/guide.md and @lisp/new.el." text))
        (should (equal (list (expand-file-name "lisp/shared.el" wt) (expand-file-name "docs/guide.md" main)
                             (expand-file-name "lisp/new.el" wt))
                       (mapcar (lambda (a) (plist-get a :path)) atts))))
      ;; Before any listing arrived: the first root with such a file has it.
      (setq harness-compose--files nil harness-compose--root-files nil harness-compose--file-origins nil)
      (harness-compose-set "@lisp/shared.el @main-only.md @nope.el")
      (should (equal (list (expand-file-name "lisp/shared.el" wt) (expand-file-name "main-only.md" main))
                     (mapcar (lambda (a) (plist-get a :path)) (cdr (harness-compose-take))))))))

(ert-deftest harness-ui-compose-attach-fills-in-the-workspace-that-lists-late ()
  "A listing still running fills its candidates in when it returns, and the
other root's, in place, are offered meanwhile.  A root that fails to list
adds nothing, and what it listed before stays.  When no root lists a
file, any file is read instead."
  (harness-ui-compose-test-with
    (harness-ui-compose-test--workspaces
      (let ((late (harness-make-promise))
            (offered nil))
        (setf (cdr (assoc main listings)) late)
        (setq harness-compose--files nil)
        (setq answer nil)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt table &rest _)
                     (setq asked table)
                     (setq offered (list (all-completions "" table)))
                     (harness-resolve late (list "shared.txt" "main-only.md" "docs/guide.md"))
                     (push (all-completions "" table) offered)
                     "docs/guide.md")))
          (harness-ui-compose-test--command 'harness-compose-add-attachment))
        ;; Meanwhile the worktree's files, then the main checkout's as well.
        (should (equal '("shared.txt" "lisp/task-only.el" "lisp/shared.el" "lisp/new.el") (cadr offered)))
        (should (equal '("shared.txt" "lisp/task-only.el" "lisp/shared.el" "lisp/new.el" "main-only.md" "docs/guide.md")
                       (car offered)))
        (should (equal (list (expand-file-name "docs/guide.md" main)) (harness-ui-compose-test--paths)))
        (should (equal '("  [main]") (harness-ui-compose-test--annotations asked '("docs/guide.md")))))
      ;; The worktree fails to list: what the main checkout lists is what there is, and what it had stays.
      (setf (cdr (assoc wt listings)) (harness-rejected '(error "no git")))
      (harness-compose-fetch-files)
      (should (equal '("shared.txt" "lisp/task-only.el" "lisp/shared.el" "lisp/new.el" "main-only.md" "docs/guide.md")
                     harness-compose--files))
      ;; Neither lists: read any file, as for a project that lists none.
      (setf (cdr (assoc wt listings)) nil
            (cdr (assoc main listings)) nil
            harness-compose--files nil harness-compose--root-files nil)
      (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) (expand-file-name "shared.txt" wt))))
        (setq harness-compose-attachments nil)
        (harness-ui-compose-test--command 'harness-compose-add-attachment))
      (should (equal (list (expand-file-name "shared.txt" wt)) (harness-ui-compose-test--paths))))))

(ert-deftest harness-ui-compose-attach-with-one-root-lists-as-it-did ()
  "A box with one root -- the host names none, or no more than the project --
lists the project's files alone, reads them from it, and marks no candidate."
  (harness-ui-compose-test-with
    (harness-ui-compose-test--files
      (dolist (roots (list nil
                           (lambda () nil)
                           (lambda () (list (cons proj "main")))
                           (lambda () (list (cons proj "task") (cons (directory-file-name proj) "main")))
                           (lambda () (error "No session"))))
        (setq harness-compose-roots-function roots
              harness-compose--files nil harness-compose--file-roots nil)
        (let ((asked nil))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt table &rest _) (setq asked table) "lisp/notes-util.el"))
                    ((symbol-function 'harness-compose-fetch-tasks) #'ignore))
            (setq harness-compose-attachments nil)
            (harness-ui-compose-test--command 'harness-compose-add-attachment))
          (should-not harness-compose--file-roots)
          (should-not (harness-compose--roots))
          (should (equal '("notes.txt" "lisp/notes-util.el") harness-compose--files))
          (should (equal (list (expand-file-name "lisp/notes-util.el" proj)) (harness-ui-compose-test--paths)))
          (should-not (completion-metadata-get (completion-metadata "" asked nil) 'annotation-function))
          (should (equal '(metadata (category . harness-compose-file))
                         (completion-metadata "" asked nil))))))))

;;;; Quoting

(defun harness-ui-compose-test--quote (&optional from to)
  "Type C-c > with the region from FROM to TO, when given; return the box's text.
The key goes through the command loop, as typed."
  (when from
    (setq-local transient-mark-mode t)
    (goto-char to)
    (push-mark from t t))
  (execute-kbd-macro (kbd "C-c >"))
  (harness-compose-text))

(ert-deftest harness-ui-compose-quote-string ()
  "Every line of a quote follows \"> \".  Blank lines around the text go,
and spaces ending a line; a blank line within it is a bare \">\", so the
quote stays one block.  Indentation stays, as code needs."
  (should (equal "> one\n>\n>   two" (compose-quote-string "\n \none  \n\t\n  two\n\n")))
  (should (equal "> one" (compose-quote-string "one"))))

(ert-deftest harness-ui-compose-quote-reply-quotes-the-region ()
  "C-c > quotes the region in the box, as Markdown, point under the quote.
The quote follows what the box holds, a blank line apart, and a blank
line follows it, so what is typed next is the reply.  Point jumps into
the box, which its windows follow.  A region reaching into the box
quotes its part above the box; one in the box becomes a quote in place."
  (harness-ui-compose-test-with
    (should (eq 'compose-quote-reply (key-binding (kbd "C-c >"))))
    (let ((jumps harness-compose--jumps))
      ;; "transcript", of "The transcript.\n".
      (should (equal "> transcript\n\n" (harness-ui-compose-test--quote (+ (point-min) 4) (+ (point-min) 14))))
      (should (= (point) harness-compose-end))
      (should (> harness-compose--jumps jumps)))
    (should-not (region-active-p))
    (execute-kbd-macro "Why?")
    (should (equal "> transcript\n\nWhy?" (harness-compose-text)))
    ;; From above the box into it: the part above, after the reply.
    (should (equal "> transcript\n\nWhy?\n\n> The transcript.\n\n"
                   (harness-ui-compose-test--quote (point-min) (+ harness-compose-start 3))))
    (should (= (point) harness-compose-end))
    ;; In the box, in place.
    (harness-compose-set "Look:\nHello\nworld")
    (should (equal "Look:\n\n> Hello\n> world\n\n"
                   (harness-ui-compose-test--quote (+ harness-compose-start 6) harness-compose-end)))
    (should (= (point) harness-compose-end))
    (should (equal "The transcript.\n" (harness-ui-compose-test--transcript)))))

(ert-deftest harness-ui-compose-quote-reply-without-a-region ()
  "Without a region C-c > quotes the message at point, whole, as written.
Text marked with a `compose-quote' property says which, else
the host's `compose-quote-function'; with neither, nothing is
quoted.  The quote goes at point in the box, else at its end."
  (harness-ui-compose-test-with
    (goto-char (point-min))
    (should-error (compose-quote-reply) :type 'user-error)
    (should (equal "" (harness-compose-text)))
    (setq-local compose-quote-function
                (lambda () (and (< (point) harness-compose-start) "The **transcript**.")))
    (goto-char (point-min))
    (should (equal "> The **transcript**.\n\n" (harness-ui-compose-test--quote)))
    (should (= (point) harness-compose-end))
    ;; The function said nothing in the box.
    (should-error (compose-quote-reply) :type 'user-error)
    ;; Marked text wins.
    (harness-compose-set "")
    (let ((inhibit-read-only t))
      (put-text-property (point-min) (+ (point-min) 3) 'compose-quote "*The*"))
    (goto-char (1+ (point-min)))
    (should (equal "> *The*\n\n" (harness-ui-compose-test--quote)))
    ;; In the box, at point.
    (harness-compose-set "Before\nAfter")
    (setq-local compose-quote-function (lambda () "Quoted"))
    (goto-char (+ harness-compose-start (length "Before\n")))
    (should (equal "Before\n\n> Quoted\n\nAfter" (harness-ui-compose-test--quote)))
    (should (= (point) (+ harness-compose-start (length "Before\n\n> Quoted\n\n"))))))

(defun harness-ui-compose-test--keys (keys)
  "Type KEYS, as `kbd' reads them, through the command loop.
The messages of the commands, \"Undo\" say, are not shown."
  (let ((inhibit-message t))
    (execute-kbd-macro (kbd keys))))

(defun harness-ui-compose-test--box-keys ()
  "Return the keys of the box, each with what it runs at point.
They are the key sequences `harness-compose-map' binds, as vectors, and
\\`C-c .', which a host may bind for the box."
  (let ((keys (list (key-parse "C-c ."))))
    (cl-labels ((walk (map prefix)
                  (map-keymap (lambda (event binding)
                                (unless (consp event)
                                  (let ((key (vconcat prefix (vector event))))
                                    (cond ((keymapp binding) (walk binding key))
                                          (binding (push key keys))))))
                              map)))
      (walk harness-compose-map []))
    (mapcar (lambda (key) (cons key (key-binding key))) (delete-dups keys))))

(ert-deftest harness-ui-compose-quote-inline-mode-follows-point ()
  "The inline mode is on while point is in a quote in the box, and off elsewhere.
\\`C-c >' quotes two lines into the box.  Point moving up into the quote
turns `compose-quote-inline-mode' on, which binds \\`M-RET' and \\`C-c ['
and leaves every other key of the box as it was; out of it, onto the
empty line under the quote or into the transcript, it is off.  A line of
the read-only transcript that starts with \">\" is not a quote of the
box: the mode stays off there."
  (harness-ui-compose-test-with
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-min))
        (insert (propertize "> The transcript's own.\nAlpha beta.\nGamma delta.\n" 'read-only t))))
    (should-not compose-quote-inline-mode)
    (should-not (key-binding (kbd "C-c [")))
    (let ((alpha (+ (point-min) (length "> The transcript's own.\n"))))
      (should (equal "> Alpha beta.\n> Gamma delta.\n\n"
                     (harness-ui-compose-test--quote alpha (+ alpha (length "Alpha beta.\nGamma delta."))))))
    ;; Under the quote.
    (should (= (point) harness-compose-end))
    (should-not compose-quote-inline-mode)
    ;; The blank line between, then the quote's last line and its first.
    (harness-ui-compose-test--keys "C-p")
    (should-not compose-quote-inline-mode)
    (harness-ui-compose-test--keys "C-p")
    (should (equal "> Gamma delta." (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
    (should compose-quote-inline-mode)
    (should (eq 'compose-quote-split (key-binding (kbd "M-RET"))))
    (should (eq 'compose-quote-elide (key-binding (kbd "C-c ["))))
    (should (eq 'compose-quote-reply (key-binding (kbd "C-c >"))))
    (harness-ui-compose-test--keys "C-p")
    (should compose-quote-inline-mode)
    ;; Up into the transcript.
    (harness-ui-compose-test--keys "C-p")
    (should (equal "The transcript." (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
    (should-not compose-quote-inline-mode)
    (should-not (key-binding (kbd "C-c [")))
    ;; The transcript's ">" line is not the box's.
    (goto-char (point-min))
    (harness-ui-compose-test--keys "C-f")
    (should (equal "> The transcript's own." (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
    (should-not compose-quote-inline-mode)
    (harness-ui-compose-test--keys "C-n")
    (should-not compose-quote-inline-mode)
    ;; Back down into the box and its quote.
    (goto-char harness-compose-start)
    (harness-ui-compose-test--keys "C-f")
    (should compose-quote-inline-mode)))

(ert-deftest harness-ui-compose-quote-leaves-the-box-keys ()
  "In a quote in the box, the box's keys do what they do out of one.
`compose-quote-inline-mode' binds \\`M-RET' and \\`C-c [', and its map
outranks the host's while point is in a quote: it shadows no other key
of the box, \\`C-c .' included, which a host may bind for the box."
  (harness-ui-compose-test-with
    (let ((outside (harness-ui-compose-test--box-keys))
          (own (mapcar #'key-parse '("M-RET" "M-<return>" "C-c ["))))
      (should (assoc (key-parse "C-c >") outside))
      (should-not compose-quote-inline-mode)
      (harness-compose-set "> The release is ready.")
      (goto-char harness-compose-start)
      (harness-ui-compose-test--keys "C-f")
      (should compose-quote-inline-mode)
      (dolist (key outside)
        (unless (member (car key) own)
          (should (equal (cons (key-description (car key)) (cdr key))
                         (cons (key-description (car key)) (key-binding (car key))))))))))

(ert-deftest harness-ui-compose-quote-answers-inline-in-the-box ()
  "In a quote in the box \\`M-RET' splits it, to answer, and \\`C-c [' elides.
\\`M-RET' with point mid-way in a quoted line splits the quote there:
its second half starts the second quote, and point is on the empty line
between them, a blank line from each, where the answer is typed.
\\`C-c [' elides the region inside the quote as [...], and without a
region the rest of the paragraph.  Undo brings the text back, each time."
  (harness-ui-compose-test-with
    (let* ((head "> The release is ready. Two things are open.\n")
           (tail "> The changelog still lists the old flag, and the migration has no test.")
           (text (concat head ">\n" tail)))
      (harness-compose-set text)
      ;; After "ready.", mid-way in the first line.
      (goto-char (+ harness-compose-start (length "> The release is ready.")))
      (harness-ui-compose-test--keys "C-b C-f")
      (should compose-quote-inline-mode)
      (harness-ui-compose-test--keys "M-RET")
      (let ((split (concat "> The release is ready.\n\n\n\n> Two things are open.\n>\n" tail)))
        (should (equal split (harness-compose-text)))
        (should (= (point) (+ harness-compose-start (length "> The release is ready.\n\n"))))
        (should-not compose-quote-inline-mode)
        ;; The answer goes between them.
        (execute-kbd-macro "Good news.")
        (let ((answered (concat "> The release is ready.\n\nGood news.\n\n> Two things are open.\n>\n" tail)))
          (should (equal answered (harness-compose-text)))
          ;; The region, from "still" to the end of the last line.
          (let ((still (+ harness-compose-start (length "> The release is ready.\n\nGood news.\n\n> Two things are open.\n>\n> The changelog "))))
            (goto-char still)
            (harness-ui-compose-test--keys "C-b C-f")
            (should compose-quote-inline-mode)
            (setq-local transient-mark-mode t)
            (goto-char harness-compose-end)
            (push-mark still t t)
            (harness-ui-compose-test--keys "C-c ["))
          (should (equal (concat "> The release is ready.\n\nGood news.\n\n> Two things are open.\n>\n"
                                 "> The changelog [...]")
                         (harness-compose-text)))
          (should-not (region-active-p))
          (harness-ui-compose-test--keys "C-/")
          (should (equal answered (harness-compose-text)))
          ;; Without a region: the rest of the paragraph from point.
          (goto-char (+ harness-compose-start (length "> The release is ready.\n\nGood news.\n\n> Two ")))
          (harness-ui-compose-test--keys "C-b C-f")
          (should compose-quote-inline-mode)
          (harness-ui-compose-test--keys "C-c [")
          (should (equal (concat "> The release is ready.\n\nGood news.\n\n> Two [...]\n>\n" tail)
                         (harness-compose-text)))
          (harness-ui-compose-test--keys "C-/")
          (should (equal answered (harness-compose-text))))))
    (should (equal "The transcript.\n" (harness-ui-compose-test--transcript)))))

(ert-deftest harness-ui-compose-quote-keeps-the-names-it-had ()
  "The box quotes with the library; the names it quoted with remain as aliases.
\\`C-c >' is `compose-quote-reply', which `harness-compose-quote-reply' now
names, as `harness-compose-quote-string' names `compose-quote-string'
and `harness-compose-quote-function' `compose-quote-function'."
  (harness-ui-compose-test-with
    (should (eq 'compose-quote-reply (key-binding (kbd "C-c >"))))
    (should (eq (indirect-function 'compose-quote-reply)
                (indirect-function 'harness-compose-quote-reply)))
    (should (eq (indirect-function 'compose-quote-string)
                (indirect-function 'harness-compose-quote-string)))
    (should (get 'harness-compose-quote-reply 'byte-obsolete-info))
    (should (equal "> one\n>\n> two" (harness-compose-quote-string "one\n\ntwo")))
    (should (eq 'compose-quote-function (indirect-variable 'harness-compose-quote-function)))
    ;; What a host sets under the old name, the library finds.
    (setq-local harness-compose-quote-function (lambda () "Old host"))
    (should (functionp compose-quote-function))
    (should (equal "> Old host\n\n" (harness-ui-compose-test--quote)))))

(ert-deftest harness-ui-compose-reload-moves-an-old-box-to-compose-quote ()
  "A harness reloading in the Emacs that ran it from before compose-quote still works.
That Emacs has a box set up the old way, its host's function for the
message at point under the old name, local in the buffer.  Emacs cannot
make a variable that is buffer-local an alias, so the file loads without
that alias, and carries on: the old box quotes in its box as a new one
does, the inline mode follows point in it, and its host's function is
found under the new name.  A fresh Emacs plays the old one, since this
one has the new file loaded."
  (let* ((dir (file-name-as-directory (make-temp-file "harness-compose-reload-" t)))
         (script (expand-file-name "old-state.el" dir))
         (emacs (expand-file-name invocation-name invocation-directory)))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert ";;; -*- lexical-binding: t -*-\n")
            (dolist (form '((defvar-local harness-compose-quote-function nil)
                            (defvar old-chat (generate-new-buffer "old chat"))
                            ;; A box set up before: its host's function, local.
                            (with-current-buffer old-chat
                              (setq-local harness-compose-quote-function (lambda () "the old host's message"))
                              (add-hook 'completion-at-point-functions 'harness-compose-completion-at-point nil t))
                            ;; The reload.
                            (require 'harness-ui-compose)
                            (with-current-buffer old-chat
                              (princ (format "mode=%S area=%S carried=%S hook=%S aliased=%S\n"
                                             compose-quote-mode compose-quote-area-function
                                             (and (functionp compose-quote-function) (funcall compose-quote-function))
                                             (and (memq 'harness-compose--quoted compose-quote-insert-hook) t)
                                             (eq 'compose-quote-function (indirect-variable 'harness-compose-quote-function)))))))
              (prin1 form (current-buffer))
              (terpri (current-buffer))))
          (let ((process-environment (cons (concat "HOME=" (directory-file-name dir)) process-environment))
                (default-directory dir))
            (with-temp-buffer
              (let ((status (call-process emacs nil t nil "--batch" "-Q"
                                          "-L" harness-test-root
                                          "-L" (expand-file-name "lisp" harness-test-root)
                                          "-L" (expand-file-name "lisp/modules" harness-test-root)
                                          "-L" (expand-file-name "lisp/ui" harness-test-root)
                                          "-l" script)))
                (ert-info ((buffer-string))
                  (should (eql 0 status))
                  (should (string-match-p
                           (regexp-quote "mode=t area=harness-compose--quote-area carried=\"the old host's message\" hook=t aliased=nil")
                           (buffer-string))))))))
      (delete-directory dir t))))

;;;; Typing outside the box

(defun harness-ui-compose-test--transcript ()
  "The host's read-only line, as it stands."
  (save-excursion
    (goto-char (point-min))
    (buffer-substring-no-properties (point) (line-beginning-position 2))))

(ert-deftest harness-ui-compose-typing-outside-goes-into-the-box ()
  "A printable character typed outside the box goes to the end of the box.
From the read-only text above it and from after its last line, and
with a region in the read-only text, which `delete-selection-mode'
would try to delete: the region is dropped instead.  The keys are read
by the command loop, as typed."
  (harness-ui-compose-test-with
    (let ((was (bound-and-true-p delete-selection-mode)))
      (unwind-protect
          (progn
            (goto-char (point-min))
            (execute-kbd-macro "hi")
            (should (equal "hi" (harness-compose-text)))
            (should (= (point) harness-compose-end))
            ;; After the box's final newline, the last place in the buffer.
            (goto-char (point-max))
            (execute-kbd-macro " there")
            (should (equal "hi there" (harness-compose-text)))
            ;; Quoting a character types it too.
            (goto-char (point-min))
            (execute-kbd-macro (kbd "C-q #"))
            (should (equal "hi there#" (harness-compose-text)))
            ;; A region in the read-only text is dropped, not deleted.
            (delete-selection-mode 1)
            (setq-local transient-mark-mode t)
            (goto-char (+ (point-min) 4))
            (push-mark (point-min) t t)
            (should (use-region-p))
            (let ((messages (harness-ui-compose-test-messages (execute-kbd-macro "!"))))
              (should-not (cl-find-if (lambda (m) (string-match-p "read-only" m)) messages)))
            (should (equal "hi there#!" (harness-compose-text)))
            (should-not (region-active-p))
            ;; In the box too, when the region reaches out of it.
            (push-mark (+ (point-min) 4) t t)
            (should (use-region-p))
            (execute-kbd-macro "?")
            (should (equal "hi there#!?" (harness-compose-text)))
            (should-not (region-active-p))
            ;; A region in the box is replaced, as typing replaces one.
            (push-mark harness-compose-start t t)
            (execute-kbd-macro "x")
            (should (equal "x" (harness-compose-text)))
            ;; RET outside the box jumps into it, dropping the region too.
            (goto-char (+ (point-min) 4))
            (push-mark (point-min) t t)
            (execute-kbd-macro (kbd "RET"))
            (should (= (point) harness-compose-end))
            (should-not (region-active-p))
            (should (equal "x" (harness-compose-text)))
            (should (equal "The transcript.\n" (harness-ui-compose-test--transcript))))
        (delete-selection-mode (if was 1 -1))))))

(defvar harness-ui-compose-test--ran nil "The test commands that ran, newest first.")

(defun harness-ui-compose-test-act ()
  "Act on the thing at point, for the tests: say so."
  (interactive)
  (push 'act harness-ui-compose-test--ran))

(put 'harness-ui-compose-test-act 'harness-compose-acts-p
     (lambda () (get-text-property (point) 'harness-ui-compose-test-thing)))

(ert-deftest harness-ui-compose-keys-outside-the-box-stay-commands ()
  "A key bound to a command outside the box runs it there.
A command with a `harness-compose-acts-p' property runs where that says
it has something to act on, and elsewhere its key types into the box.
A key that does nothing where it is typed -- `undefined', as a keymap
suppressing typing has it -- types too."
  (harness-ui-compose-test-with
    (let* ((harness-ui-compose-test--ran nil)
           (map (make-sparse-keymap))
           (suppressed (make-sparse-keymap))
           (inhibit-read-only t))
      (define-key map "q" (lambda () (interactive) (push 'quit harness-ui-compose-test--ran)))
      (define-key map "u" #'undefined)
      (define-key map "k" #'harness-ui-compose-test-act)
      (suppress-keymap suppressed t)
      ;; "The " is a thing `k' acts on, "transcript" suppresses typing,
      ;; and the rest of the line has neither.
      (put-text-property (point-min) (+ (point-min) (length "The transcript.\n")) 'keymap map)
      (put-text-property (point-min) (+ (point-min) 4) 'harness-ui-compose-test-thing t)
      (put-text-property (+ (point-min) 4) (+ (point-min) 14) 'keymap suppressed)
      (goto-char (+ (point-min) 2))
      (execute-kbd-macro "q")
      (should (equal '(quit) harness-ui-compose-test--ran))
      (execute-kbd-macro "k")
      (should (equal '(act quit) harness-ui-compose-test--ran))
      (should (= (point) (+ (point-min) 2)))
      (should (equal "" (harness-compose-text)))
      ;; Off the thing, `k' has nothing to act on: it types.  Its
      ;; binding stays, for help to show.
      (goto-char (+ (point-min) 14))
      (should (eq 'harness-ui-compose-test-act (key-binding "k")))
      (execute-kbd-macro "k")
      (should (equal "k" (harness-compose-text)))
      (should (equal '(act quit) harness-ui-compose-test--ran))
      ;; A key that is `undefined', or a letter a keymap suppresses, types.
      (goto-char (+ (point-min) 14))
      (should (eq 'undefined (key-binding "u")))
      (execute-kbd-macro "u")
      (goto-char (+ (point-min) 6))
      (should (eq 'undefined (key-binding "z")))
      (execute-kbd-macro "z")
      (should (equal "kuz" (harness-compose-text)))
      ;; Called otherwise than by its printable key, it runs as usual.
      (goto-char (+ (point-min) 14))
      (execute-kbd-macro (kbd "M-x harness-ui-compose-test-act RET"))
      (should (equal '(act act quit) harness-ui-compose-test--ran))
      (should (equal "kuz" (harness-compose-text)))
      (should (equal "The transcript.\n" (harness-ui-compose-test--transcript))))))

;;;; A panel's key, from the box

(defvar harness-ui-compose-test--pressed nil
  "What the keys of the test panels did, newest first: (PANEL KEY POINT).")

(defun harness-ui-compose-test--panel-map (name &rest keys)
  "Return the keymap of the test panel NAME: each of KEYS records its press."
  (let ((map (make-sparse-keymap)))
    (dolist (key keys)
      (define-key map key
        (lambda () (interactive) (push (list name key (point)) harness-ui-compose-test--pressed))))
    map))

(defun harness-ui-compose-test--two-panels ()
  "Return two panels: one, farther from the box and holding a thing, and two.
Both bind k; one binds z too."
  (list (list "one" (propertize "Panel one\n" 'harness-ui-compose-test-thing t)
              (harness-ui-compose-test--panel-map "one" "k" "z"))
        (list "two" "Panel two\n" (harness-ui-compose-test--panel-map "two" "k"))))

(defun harness-ui-compose-test--panel-key (keys &optional n)
  "Call `harness-compose-panel-key' with N, the keys KEYS typed after it."
  (cl-letf (((symbol-function 'read-key-sequence) (lambda (&rest _) keys)))
    (harness-compose-panel-key n)))

(ert-deftest harness-ui-compose-panel-key-presses-a-key-on-the-panel-above ()
  "C-c . reads a key and runs it on the nearest panel above the box that binds it.
The command runs with point on the panel, and point is back in the box,
at the offset it had, after.  A numeric argument takes the Nth panel up.
The keys go through the command loop, as typed."
  (harness-ui-compose-test-with
    (setq harness-ui-compose-test--panels (harness-ui-compose-test--two-panels))
    (harness-ui-compose-test--draw)
    (let* ((one (+ (point-min) (length "The transcript.\n")))
           (two (+ one (length "Panel one\n")))
           (harness-ui-compose-test--pressed nil))
      (should (eq 'harness-compose-panel-key (key-binding (kbd "C-c ."))))
      (harness-compose-set "draft")
      (goto-char (+ harness-compose-start 2))
      ;; k is bound by both: the nearest to the box is two.
      (execute-kbd-macro (kbd "C-c . k"))
      (should (equal `(("two" "k" ,two)) harness-ui-compose-test--pressed))
      (should (= (point) (+ harness-compose-start 2)))
      (should (equal "draft" (harness-compose-text)))
      ;; z is bound by one alone.
      (execute-kbd-macro (kbd "C-c . z"))
      (should (equal `("one" "z" ,one) (car harness-ui-compose-test--pressed)))
      ;; With a numeric argument, the second panel up that binds the key.
      (execute-kbd-macro (kbd "C-u 2 C-c . k"))
      (should (equal `("one" "k" ,one) (car harness-ui-compose-test--pressed)))
      (should (= 3 (length harness-ui-compose-test--pressed)))
      (should (= (point) (+ harness-compose-start 2)))
      (should (equal "draft" (harness-compose-text)))
      ;; Typed with point elsewhere, the key presses all the same, and point stays.
      (goto-char (+ (point-min) 4))
      (execute-kbd-macro (kbd "C-c . k"))
      (should (equal `("two" "k" ,two) (car harness-ui-compose-test--pressed)))
      (should (= (point) (+ (point-min) 4)))
      ;; Without a box there is nothing to press a key from.
      (with-temp-buffer
        (let ((err (should-error (harness-compose-panel-key) :type 'user-error)))
          (should (equal "No compose box here" (cadr err))))))))

(ert-deftest harness-ui-compose-panel-key-says-when-no-panel-has-the-key ()
  "A key no panel binds is no key to press, whatever the buffer does with it.
Typing, the box's own keys and the buffer's are not a panel's; asking for
more panels than bind the key is said too, and nothing runs."
  (harness-ui-compose-test-with
    (setq harness-ui-compose-test--panels (harness-ui-compose-test--two-panels))
    (harness-ui-compose-test--draw)
    (harness-compose-set "draft")
    (goto-char (+ harness-compose-start 2))
    (let ((harness-ui-compose-test--pressed nil))
      (dolist (keys '("q" "x" "\C-f" "\r" "\C-c\C-a"))
        (let ((err (should-error (harness-ui-compose-test--panel-key keys) :type 'user-error)))
          (should (equal (format "No panel above the box has %s" (key-description keys)) (cadr err)))))
      (let ((err (should-error (harness-ui-compose-test--panel-key "k" 3) :type 'user-error)))
        (should (equal "Fewer than 3 panels above the box have k" (cadr err))))
      (let ((err (should-error (harness-ui-compose-test--panel-key "z" 2) :type 'user-error)))
        (should (equal "Fewer than 2 panels above the box have z" (cadr err))))
      (should-not harness-ui-compose-test--pressed)
      (should (= (point) (+ harness-compose-start 2)))
      (should (equal "draft" (harness-compose-text))))
    ;; The prompt says how to get out, and which panel the number asks for.
    (let ((prompts nil))
      (cl-letf (((symbol-function 'read-key-sequence)
                 (lambda (prompt &rest _) (push prompt prompts) "q")))
        (ignore-errors (harness-compose-panel-key))
        (ignore-errors (harness-compose-panel-key 2)))
      (should (equal '("Key for panel 2 above (C-g quits): "
                       "Key for the panel above (C-g quits): ")
                     prompts)))))

(ert-deftest harness-ui-compose-panel-key-skips-a-panel-with-nothing-to-act-on ()
  "A panel's key for what point is on has nothing to act on from the box.
The panel is passed over for a farther one whose command has; with none
it is said, and nothing runs."
  (harness-ui-compose-test-with
    (let ((panels (harness-ui-compose-test--two-panels))
          (harness-ui-compose-test--ran nil))
      (dolist (panel panels)
        (define-key (nth 2 panel) "i" #'harness-ui-compose-test-act))
      (setq harness-ui-compose-test--panels panels)
      (harness-ui-compose-test--draw)
      (goto-char harness-compose-end)
      ;; Panel one holds a thing for `i' to act on, panel two none.
      (execute-kbd-macro (kbd "C-c . i"))
      (should (equal '(act) harness-ui-compose-test--ran))
      (let ((inhibit-read-only t))
        (remove-text-properties (point-min) (point-max) '(harness-ui-compose-test-thing nil)))
      (let ((err (should-error (harness-ui-compose-test--panel-key "i") :type 'user-error)))
        (should (string-match-p "\\`i has nothing to act on from the box" (cadr err))))
      (should (equal '(act) harness-ui-compose-test--ran))
      (should (= (point) harness-compose-end)))))

(ert-deftest harness-ui-compose-panel-key-returns-point-to-the-box ()
  "Point ends in the box when the host drew the panels and the box again.
The command runs with point on the panel, and a host that draws again
what is below its transcript puts point in the box (a chat does), leaves
it where the text it was in went (a panel that goes with the answer) or
after the box (a host that draws the whole buffer): whichever, it goes
back to its offset in the box.  It stays where a command took it
elsewhere, when that is above the box and on no panel."
  (harness-ui-compose-test-with
    (let ((map (make-sparse-keymap)))
      ;; As a chat draws its tail: point on a panel goes to the end of the box.
      (define-key map "r" (lambda ()
                            (interactive)
                            (let ((in-tail (not (harness-compose-in-p))))
                              (harness-ui-compose-test--draw)
                              (when in-tail (goto-char harness-compose-end)))))
      ;; As answering a question does: the panel goes, point stays where it began.
      (define-key map "d" (lambda ()
                            (interactive)
                            (let ((inhibit-read-only t))
                              (delete-region (point) (+ (point) (length "Panel one\n"))))))
      ;; As a host that draws the whole buffer again does: point ends after the box.
      (define-key map "n" (lambda () (interactive) (harness-ui-compose-test--draw)))
      (define-key map "g" (lambda () (interactive) (goto-char (point-min))))
      (define-key map "e" (lambda () (interactive) (error "Boom")))
      (setq harness-ui-compose-test--panels (list (list "one" "Panel one\n" map)))
      (harness-ui-compose-test--draw)
      (harness-compose-set "draft")
      (goto-char (+ harness-compose-start 3))
      (let ((draws harness-ui-compose-test--draws))
        (execute-kbd-macro (kbd "C-c . r"))
        (should (> harness-ui-compose-test--draws draws)))
      (should (= (point) (+ harness-compose-start 3)))
      (should (equal "draft" (harness-compose-text)))
      (execute-kbd-macro (kbd "C-c . n"))
      (should (= (point) (+ harness-compose-start 3)))
      (should (equal "draft" (harness-compose-text)))
      ;; A command that fails leaves point in the box too.
      (let ((err (should-error (harness-ui-compose-test--panel-key "e") :type 'error)))
        (should (equal "Boom" (cadr err))))
      (should (= (point) (+ harness-compose-start 3)))
      ;; Here a command took it elsewhere: the top of the buffer.
      (execute-kbd-macro (kbd "C-c . g"))
      (should (= (point) (point-min)))
      ;; The panel goes, with point where it was.
      (goto-char (+ harness-compose-start 4))
      (execute-kbd-macro (kbd "C-c . d"))
      (should-not (text-property-not-all (point-min) (point-max) 'harness-compose-panel nil))
      (should (= (point) (+ harness-compose-start 4)))
      (should (equal "draft" (harness-compose-text))))))

(ert-deftest harness-ui-compose-panel-pieces-with-equal-names-are-one-panel ()
  "A panel drawn in pieces, their names `equal' but not `eq', is one panel.
A redraw in place of the options of a question makes such pieces.  The
panel starts at its first piece, and the pieces are not counted twice."
  (harness-ui-compose-test-with
    (let ((map (harness-ui-compose-test--panel-map "one" "k"))
          (other (harness-ui-compose-test--panel-map "two" "k"))
          (harness-ui-compose-test--pressed nil))
      (setq harness-ui-compose-test--panels
            (list (list (copy-sequence "one") "First piece\n" map)
                  (list (copy-sequence "one") "Second piece\n" map)
                  (list "two" "Panel two\n" other)))
      (harness-ui-compose-test--draw)
      (let ((one (+ (point-min) (length "The transcript.\n"))))
        (execute-kbd-macro (kbd "C-c . k"))
        (should (equal "two" (car (car harness-ui-compose-test--pressed))))
        (execute-kbd-macro (kbd "C-u 2 C-c . k"))
        (should (equal `("one" "k" ,one) (car harness-ui-compose-test--pressed)))
        (let ((err (should-error (harness-ui-compose-test--panel-key "k" 3) :type 'user-error)))
          (should (equal "Fewer than 3 panels above the box have k" (cadr err))))))))

(ert-deftest harness-ui-compose-panel-key-hint-follows-the-binding ()
  "The hints name the key where `harness-compose-panel-key' is bound.
A panel's hint is dim, its key a key, whatever the key it names."
  (harness-ui-compose-test-with
    (should (equal "C-c ." (harness-compose-panel-keys)))
    (let ((hint (harness-compose-panel-hint "y"))
          (face-p (lambda (string pos face)
                    (let ((faces (get-text-property pos 'face string)))
                      (if (listp faces) (memq face faces) (eq face faces))))))
      (should (equal "from the box: C-c . y" (substring-no-properties hint)))
      (should (funcall face-p hint 0 'harness-dim-face))
      (should (funcall face-p hint (string-search "C-c" hint) 'harness-ui-key-face))
      (should (funcall face-p hint (1- (length hint)) 'harness-ui-key-face)))
    (let ((old (lookup-key harness-compose-map (kbd "C-c ."))))
      (unwind-protect
          (progn
            (define-key harness-compose-map (kbd "C-c .") nil)
            (define-key harness-compose-map (kbd "C-c ,") #'harness-compose-panel-key)
            (should (equal "C-c ," (harness-compose-panel-keys)))
            (should (equal "from the box: C-c , 1" (substring-no-properties (harness-compose-panel-hint "1")))))
        (define-key harness-compose-map (kbd "C-c ,") nil)
        (define-key harness-compose-map (kbd "C-c .") old)))
    (should (equal "C-c ." (harness-compose-panel-keys)))))

;;;; The top and the bottom of the box

(ert-deftest harness-ui-compose-m-less-and-m-greater-go-to-the-edges-of-the-box ()
  "M-< and M-> go to the top and the bottom of the box, then of the buffer.
From outside the box, with an argument and from the edge already they
are the buffer's, so a second press goes on to the buffer's edge.  The
mark is left behind as `beginning-of-buffer' leaves it, but for an
active region.  The keys go through the command loop."
  (harness-ui-compose-test-with
    (harness-compose-set "one\ntwo\nthree")
    (should (eq 'harness-compose-beginning-of-buffer (key-binding (kbd "M-<"))))
    (should (eq 'harness-compose-end-of-buffer (key-binding (kbd "M->"))))
    ;; The commands' other keys agree.
    (should (eq 'harness-compose-beginning-of-buffer (key-binding (kbd "C-<home>"))))
    (should (eq 'harness-compose-end-of-buffer (key-binding (kbd "C-<end>"))))
    (goto-char (+ harness-compose-start 5))
    (execute-kbd-macro (kbd "M-<"))
    (should (= (point) harness-compose-start))
    (should (= (mark t) (+ harness-compose-start 5)))
    ;; From the top of the box: the top of the buffer.
    (execute-kbd-macro (kbd "M-<"))
    (should (= (point) (point-min)))
    ;; Outside the box the bottom is the buffer's.
    (goto-char (+ (point-min) 3))
    (execute-kbd-macro (kbd "M->"))
    (should (= (point) (point-max)))
    ;; In the box, its bottom; then the buffer's.
    (goto-char (+ harness-compose-start 5))
    (execute-kbd-macro (kbd "M->"))
    (should (= (point) harness-compose-end))
    (should (= (mark t) (+ harness-compose-start 5)))
    (execute-kbd-macro (kbd "M->"))
    (should (= (point) (point-max)))
    ;; Outside the box the top is the buffer's too.
    (goto-char (+ harness-compose-start 5))
    (execute-kbd-macro (kbd "M-<"))
    (goto-char (+ (point-min) 3))
    (execute-kbd-macro (kbd "M-<"))
    (should (= (point) (point-min)))
    ;; An argument: the buffer's, whatever the box.
    (goto-char (+ harness-compose-start 5))
    (execute-kbd-macro (kbd "C-u M-<"))
    (should (= (point) (point-min)))
    (goto-char (+ harness-compose-start 5))
    (execute-kbd-macro (kbd "C-u M->"))
    (should (= (point) (point-max)))
    ;; Where the box is empty its edges are one, which is the edge already.
    (harness-compose-set "")
    (goto-char harness-compose-start)
    (execute-kbd-macro (kbd "M->"))
    (should (= (point) (point-max)))
    (goto-char harness-compose-start)
    (execute-kbd-macro (kbd "M-<"))
    (should (= (point) (point-min)))))

(ert-deftest harness-ui-compose-m-less-leaves-an-active-region-alone ()
  "With the region active the mark stays where it is, as for `beginning-of-buffer'."
  (harness-ui-compose-test-with
    (harness-compose-set "one\ntwo\nthree")
    (setq-local transient-mark-mode t)
    (goto-char (+ harness-compose-start 8))
    (push-mark (+ harness-compose-start 2) t t)
    (should (region-active-p))
    (execute-kbd-macro (kbd "M-<"))
    (should (= (point) harness-compose-start))
    (should (= (mark t) (+ harness-compose-start 2)))
    (goto-char (+ harness-compose-start 8))
    (execute-kbd-macro (kbd "M->"))
    (should (= (point) harness-compose-end))
    (should (= (mark t) (+ harness-compose-start 2)))))

;;;; Tokens of files and tasks

(defun harness-ui-compose-test--chip (token)
  "Return the overlay of the inline chip over TOKEN in the box, or nil."
  (cl-find token harness-compose--token-overlays
           :key (lambda (ov) (buffer-substring-no-properties (overlay-start ov) (overlay-end ov)))
           :test #'equal))

(defun harness-ui-compose-test--chip-shows (ov)
  "Return what the inline chip OV shows: its icon, if any, then its name."
  (concat (substring-no-properties (or (overlay-get ov 'before-string) ""))
          (substring-no-properties (overlay-get ov 'display))))

(defun harness-ui-compose-test--click (ov &optional key)
  "Click the inline chip OV with KEY, mouse-1 by default, as its keymap has it."
  (funcall (lookup-key (overlay-get ov 'keymap) (or key [mouse-1])) nil))

(defun harness-ui-compose-test--menu-item (att name)
  "Return the command of the item NAME in the menu of the inline chip of ATT."
  (aref (cl-find name (cdr (harness-compose--chip-menu att)) :key (lambda (item) (aref item 0)) :test #'equal)
        1))

(defmacro harness-ui-compose-test--tasks (&rest body)
  "Run BODY with the box's project listing two tasks, as the task module would.
`fix' is the id of the first, working, with a session; `docs' the id of
the second, waiting, with none.  Listing the tasks again lists those."
  (declare (indent 0))
  `(let ((fix "t-1a2b3c4d") (docs "t-5e6f7a8b"))
     (setq harness-compose--tasks
           (list (list :id fix :name "Fix the login bug" :prompt "The login form rejects good passwords."
                       :column 'active :state 'active :priority 'high :session "s-123"
                       :branch "task/fix-1a2b3c4d")
                 (list :id docs :name "Write the docs" :prompt "Document the API."
                       :column 'pending :state 'pending :priority 'medium)))
     (cl-letf (((symbol-function 'harness-compose-fetch-tasks)
                (lambda (&optional callback) (when callback (funcall callback)))))
       ,@body)))

(ert-deftest harness-ui-compose-file-references-are-chips ()
  "C-c C-a of a project file puts @ and its path in the project where point is.
The reference is the file's token: a chip shows it, the file's icon
then @ and its name, which mouse-1 opens.  The file is in the list
above the box, and the message keeps the reference in its text.  The
keys go through the command loop."
  (harness-ui-compose-test-with
    (harness-ui-compose-test--files
      (let ((util (expand-file-name "lisp/notes-util.el" proj))
            (opened nil))
        (harness-compose-set "see  please")
        (goto-char (+ harness-compose-start (length "see ")))
        (harness-ui-compose-test--attaching util (execute-kbd-macro (kbd "C-c C-a")))
        (should (equal "see @lisp/notes-util.el please" (harness-compose-text)))
        (should (= (point) (+ harness-compose-start (length "see @lisp/notes-util.el"))))
        (should (equal (list util) (harness-ui-compose-test--paths)))
        (should (equal "lisp/notes-util.el" (plist-get (car harness-compose-attachments) :ref)))
        ;; The list above the box names it too (by its name alone here,
        ;; the project being in the state directory).
        (save-excursion
          (goto-char (point-min))
          (should (search-forward "notes-util.el (" harness-compose-start t)))
        ;; Inline: the file's icon, then @ and its name.
        (let ((ov (harness-ui-compose-test--chip "@lisp/notes-util.el")))
          (should ov)
          (should (equal "@lisp/notes-util.el" (overlay-get ov 'harness-compose-token)))
          (should (equal "@notes-util.el" (substring-no-properties (overlay-get ov 'display))))
          (should (string-prefix-p (substring-no-properties (harness-ui-icon 'harness-icon-file))
                                   (harness-ui-compose-test--chip-shows ov)))
          (should (string-match-p "\\`file: .*/lisp/notes-util\\.el · mouse-1: open"
                                  (overlay-get ov 'help-echo)))
          (cl-letf (((symbol-function 'find-file-other-window) (lambda (file &rest _) (setq opened file))))
            (harness-ui-compose-test--click ov))
          (should (equal util opened)))
        ;; Sent, the text keeps the reference, and the file goes once.
        (pcase-let ((`(,text . ,atts) (harness-compose-take)))
          (should (equal "see @lisp/notes-util.el please" text))
          (should (equal (list util) (mapcar (lambda (a) (plist-get a :path)) atts))))))))

(ert-deftest harness-ui-compose-file-references-and-attachments-agree ()
  "A file's reference and the file come and go together.
DEL right after the reference deletes the whole of it and detaches the
file, and undo brings both back; the × of the file's line deletes the
reference too, and typing the reference back attaches the file again.
A file whose name has a space can be no reference: it attaches with
none, the text left as it is.  The keys go through the command loop."
  (harness-ui-compose-test-with
    (harness-ui-compose-test--files
      (let ((notes (expand-file-name "notes.txt" proj))
            (spaced (expand-file-name "my notes.txt" proj)))
        (with-temp-file spaced (insert "x"))
        (goto-char harness-compose-end)
        (execute-kbd-macro "see ")
        (harness-ui-compose-test--attaching notes (execute-kbd-macro (kbd "C-c C-a")))
        (execute-kbd-macro "now")
        (should (equal "see @notes.txt now" (harness-compose-text)))
        (should (harness-ui-compose-test--chip "@notes.txt"))
        ;; DEL right after the reference deletes the whole of it, and the file.
        (goto-char (+ harness-compose-start (length "see @notes.txt")))
        (execute-kbd-macro (kbd "DEL"))
        (should (equal "see  now" (harness-compose-text)))
        (should-not harness-compose-attachments)
        (should-not harness-compose--token-overlays)
        (save-excursion (goto-char (point-min)) (should-not (search-forward "notes.txt" harness-compose-start t)))
        ;; Undo brings both back.
        (execute-kbd-macro (kbd "C-/"))
        (should (equal "see @notes.txt now" (harness-compose-text)))
        (should (equal (list notes) (harness-ui-compose-test--paths)))
        (should (equal "notes.txt" (plist-get (car harness-compose-attachments) :ref)))
        (should (harness-ui-compose-test--chip "@notes.txt"))
        (should (equal "The transcript.\n" (harness-ui-compose-test--transcript)))
        ;; The × of its line takes the reference along...
        (save-excursion
          (goto-char (point-min))
          (search-forward "notes.txt (" harness-compose-start)
          (search-forward "×" harness-compose-start)
          (push-button (1- (point))))
        (should (equal "see now" (harness-compose-text)))
        (should-not harness-compose-attachments)
        ;; ... and typing it back attaches the file again.
        (goto-char harness-compose-end)
        (execute-kbd-macro " @notes.txt")
        (should (equal (list notes) (harness-ui-compose-test--paths)))
        (should (harness-ui-compose-test--chip "@notes.txt"))
        ;; A word typed against it makes another word, which names no file.
        (execute-kbd-macro "s")
        (should-not harness-compose-attachments)
        (execute-kbd-macro (kbd "DEL"))
        (should (equal (list notes) (harness-ui-compose-test--paths)))
        ;; A name with a space can be no reference: no token, the text as it was.
        (harness-ui-compose-test--attaching spaced (execute-kbd-macro (kbd "C-c C-a")))
        (should (equal "see now @notes.txt" (harness-compose-text)))
        (should (equal (list notes spaced) (harness-ui-compose-test--paths)))
        (should-not (plist-get (nth 1 harness-compose-attachments) :ref))
        (should (= 1 (length harness-compose--token-overlays)))
        (execute-kbd-macro " both")
        (should (equal (list notes spaced) (harness-ui-compose-test--paths)))))))

(ert-deftest harness-ui-compose-images-and-files-show-the-same-chip ()
  "An image's token and a file's reference show as the same chip.
Both come from `harness-compose--inline-chip', with the same face and
the same keymap: mouse-1 and mouse-2 open, mouse-3 pops up a menu,
whose press pops up no other.  The tooltip says what the chip is and
so.  The menu opens the attachment, removes it, its token too, and
copies its path."
  (harness-ui-compose-test-with
    (harness-ui-compose-test--files
      (let ((image (plist-get (harness-media-ring-save harness-test-png "image/png") :path))
            (notes (expand-file-name "notes.txt" proj))
            (chipped nil))
        (advice-add 'harness-compose--inline-chip :before
                    (lambda (_beg _end att) (push (plist-get att :path) chipped))
                    '((name . harness-ui-compose-test)))
        (unwind-protect
            (progn
              (harness-compose-add-attachment image)
              (harness-compose-add-attachment notes))
          (advice-remove 'harness-compose--inline-chip 'harness-ui-compose-test))
        (should (equal "[image 1] @notes.txt " (harness-compose-text)))
        (should (member image chipped))
        (should (member notes chipped))
        (let ((image-chip (harness-ui-compose-test--chip "[image 1]"))
              (file-chip (harness-ui-compose-test--chip "@notes.txt")))
          (dolist (ov (list image-chip file-chip))
            (let ((map (overlay-get ov 'keymap))
                  (shown (overlay-get ov 'display)))
              (should (equal (list 'harness-compose-token-face harness-compose--face)
                             (get-text-property 0 'face shown)))
              (should (eq map (get-text-property 0 'keymap shown)))
              (should (equal (overlay-get ov 'help-echo) (get-text-property 0 'help-echo shown)))
              (should (string-suffix-p ": open · mouse-3: more · deleting it removes the attachment"
                                       (overlay-get ov 'help-echo)))
              (should (commandp (lookup-key map [mouse-1])))
              (should (eq (lookup-key map [mouse-1]) (lookup-key map [mouse-2])))
              (should (commandp (lookup-key map [mouse-3])))
              (should (eq 'ignore (lookup-key map [down-mouse-3])))))
          (should (equal "[image 1]" (substring-no-properties (overlay-get image-chip 'display))))
          (should (string-prefix-p "image 1: " (overlay-get image-chip 'help-echo)))
          (should (string-prefix-p "file: " (overlay-get file-chip 'help-echo)))
          ;; The menu: each item a command, for `popup-menu'.
          (let ((att (overlay-get file-chip 'harness-compose-attachment))
                (kill-ring nil) (kill-ring-yank-pointer nil)
                (interprogram-cut-function nil) (interprogram-paste-function nil)
                (opened nil))
            (should (equal "file" (car (harness-compose--chip-menu att))))
            (should (equal "image 1" (car (harness-compose--chip-menu (overlay-get image-chip 'harness-compose-attachment)))))
            (should (equal '("Open" "Remove from the message" "Copy the path")
                           (mapcar (lambda (item) (aref item 0)) (cdr (harness-compose--chip-menu att)))))
            (dolist (item (cdr (harness-compose--chip-menu att)))
              (should (commandp (aref item 1))))
            (cl-letf (((symbol-function 'find-file-other-window) (lambda (file &rest _) (setq opened file))))
              (call-interactively (harness-ui-compose-test--menu-item att "Open")))
            (should (equal notes opened))
            (call-interactively (harness-ui-compose-test--menu-item att "Copy the path"))
            (should (equal notes (current-kill 0)))
            (call-interactively (harness-ui-compose-test--menu-item att "Remove from the message"))
            (should (equal "[image 1] " (harness-compose-text)))
            (should (equal (list image) (harness-ui-compose-test--paths)))))))))

(ert-deftest harness-ui-compose-tasks-attach-as-text ()
  "A task attached puts @task:ID where point is, a chip that opens the task.
The chip shows the task's icon, its id and title; its line in the list
its id, title and column, and ×.  The message keeps the reference in
its text, and the task goes as text: its title, column, priority,
session and branch, then its prompt, cut when long.  A click opens the
task's session, or its card on the board while it has none.  Deleting
the reference detaches the task, and undo brings it back."
  (harness-ui-compose-test-with
    (harness-ui-compose-test--tasks
      (harness-compose-set "look at  first")
      (goto-char (+ harness-compose-start (length "look at ")))
      (harness-compose-attach-task fix)
      (should (equal "look at @task:t-1a2b3c4d first" (harness-compose-text)))
      (let ((att (car harness-compose-attachments)))
        (should (equal fix (plist-get att :task)))
        (should (equal "Fix the login bug" (plist-get att :name)))
        (should (equal "active" (plist-get att :state)))
        (should (equal "task:t-1a2b3c4d" (plist-get att :ref)))
        (should (equal harness-compose-task-mime (plist-get att :mime)))
        (should-not (plist-get att :path))
        ;; Attached once.
        (should (equal '("Task t-1a2b3c4d is attached already")
                       (harness-ui-compose-test-messages (harness-compose-attach-task fix))))
        (should (equal "look at @task:t-1a2b3c4d first" (harness-compose-text)))
        ;; Inline: the task's icon, @task:ID and its title.
        (let ((ov (harness-ui-compose-test--chip "@task:t-1a2b3c4d")))
          (should (equal "@task:t-1a2b3c4d Fix the login bug" (substring-no-properties (overlay-get ov 'display))))
          (should (string-prefix-p (substring-no-properties (harness-ui-icon 'harness-icon-task))
                                   (harness-ui-compose-test--chip-shows ov)))
          (should (string-prefix-p "task t-1a2b3c4d: Fix the login bug (active) · mouse-1: open"
                                   (overlay-get ov 'help-echo))))
        ;; Its line in the list.
        (save-excursion
          (goto-char (point-min))
          (should (search-forward "t-1a2b3c4d · Fix the login bug (active) ×" harness-compose-start t)))
        ;; Sent: the reference stays in the text, the task goes as text.
        (pcase-let ((`(,text . ,atts) (harness-compose-take)))
          (should (equal "look at @task:t-1a2b3c4d first" text))
          (should (equal (list att) atts)))
        (let* ((block (harness-compose-attachment-block att))
               (text (plist-get block :text)))
          (should (equal "text" (plist-get block :type)))
          (dolist (line '("Task t-1a2b3c4d, attached: Fix the login bug\n" "Column: active\n" "Priority: high\n"
                          "Session: s-123\n" "Branch: task/fix-1a2b3c4d\n"
                          "Prompt:\nThe login form rejects good passwords.\n" "task_list" "session_read"))
            (should (string-search line text)))
          (should-not (string-search "State:" text))
          (should-not (string-search "cut here" text))
          ;; It is marked as an attachment's text, which the harness keeps.
          (should (equal '(:attached t) (plist-get block :_harness)))
          (let ((read (harness-acp--block-from-acp block)))
            (should (equal "text" (plist-get read :type)))
            (should (equal text (plist-get read :text)))
            (should (eq t (plist-get read :attached))))
          ;; The agent makes the same block of it.
          (should (equal (list (harness-acp--block-from-acp block)) (harness-agent-attachments-to-blocks (list att)))))
        ;; A long prompt is cut, and says so.
        (let ((text (harness-compose--task-text (list :id "t-long" :name "Long" :prompt (make-string 5000 ?x)))))
          (should (string-search "[The prompt is cut here: 3000 of its 5000 characters.]" text))
          (should (string-search (make-string 3000 ?x) text))
          (should-not (string-search (make-string 3001 ?x) text)))
        ;; Its menu copies its id.
        (let ((kill-ring nil) (kill-ring-yank-pointer nil)
              (interprogram-cut-function nil) (interprogram-paste-function nil))
          (should (equal "task t-1a2b3c4d" (car (harness-compose--chip-menu att))))
          (call-interactively (harness-ui-compose-test--menu-item att "Copy the task id"))
          (should (equal fix (current-kill 0)))))
      ;; A click opens the task's session; one with none, its card on the board.
      (harness-compose-attach-task docs)
      (should (equal "look at @task:t-1a2b3c4d @task:t-5e6f7a8b first" (harness-compose-text)))
      (let ((shown nil))
        (cl-letf (((symbol-function 'harness-ui-display-session)
                   (lambda (id &rest _) (push (list 'session id) shown)))
                  ((symbol-function 'harness-ui-tasks-show-task)
                   (lambda (id project) (push (list 'board id project) shown))))
          (harness-ui-compose-test--click (harness-ui-compose-test--chip "@task:t-1a2b3c4d"))
          (harness-ui-compose-test--click (harness-ui-compose-test--chip "@task:t-5e6f7a8b") [mouse-2]))
        (should (equal (list (list 'session "s-123") (list 'board docs (harness-compose--root)))
                       (nreverse shown))))
      ;; Removed by its id, its reference goes too.
      (harness-compose-remove-attachment (concat "task:" docs))
      (should (equal "look at @task:t-1a2b3c4d first" (harness-compose-text)))
      (should (equal (list fix) (mapcar (lambda (a) (plist-get a :task)) harness-compose-attachments)))
      ;; Deleting the reference detaches the task; undo brings it back.
      (goto-char (+ harness-compose-start (length "look at @task:t-1a2b3c4d")))
      (execute-kbd-macro (kbd "DEL"))
      (should (equal "look at  first" (harness-compose-text)))
      (should-not harness-compose-attachments)
      (execute-kbd-macro (kbd "C-/"))
      (should (equal "look at @task:t-1a2b3c4d first" (harness-compose-text)))
      (should (equal (list fix) (mapcar (lambda (a) (plist-get a :task)) harness-compose-attachments)))
      ;; A task the project does not list attaches nothing.
      (should (equal '("No task t-nope in this project")
                     (harness-ui-compose-test-messages (harness-compose-attach-task "t-nope"))))
      (should (= 1 (length harness-compose-attachments))))))

(ert-deftest harness-ui-compose-at-task-completes-task-ids ()
  "@task: completes the id of a task of the project, with its title and column.
The task chosen is attached, its reference staying in the text, a space
after it to type on.  The attach command takes task:ID as well, which
completes the same way, and so does the command attaching a task, by
its title; an @task: reference names no file."
  (harness-ui-compose-test-with
    (harness-ui-compose-test--files
      (harness-ui-compose-test--tasks
        (goto-char harness-compose-end)
        (insert "ask @task:t-1")
        (let ((capf (harness-compose-completion-at-point)))
          (should (equal "t-1" (buffer-substring (nth 0 capf) (nth 1 capf))))
          (should (equal (list fix) (harness-ui-compose-test--matches "t-1" (nth 2 capf))))
          (should (equal (list docs fix) (all-completions "" (nth 2 capf))))
          (should (eq 'harness-compose-task (harness-ui-compose-test--category "" (nth 2 capf))))
          (should (equal "  Fix the login bug  [active]"
                         (funcall (plist-get (nthcdr 3 capf) :annotation-function) fix)))
          (harness-ui-compose-test--complete capf fix 'finished))
        (should (equal "ask @task:t-1a2b3c4d " (harness-compose-text)))
        (should (= (point) harness-compose-end))
        (should (equal (list fix) (mapcar (lambda (a) (plist-get a :task)) harness-compose-attachments)))
        (should (harness-ui-compose-test--chip "@task:t-1a2b3c4d"))
        (should-not (harness-compose--reference-file (concat "task:" fix) (harness-compose--root)))
        ;; The attach command's table: after task:, the ids.
        (let ((table (harness-compose--attach-table)))
          (should (equal (list fix) (all-completions "task:t-1" table)))
          (should (equal "task:t-1a2b3c4d" (try-completion "task:t-1" table)))
          (should (equal '(5 . 0) (completion-boundaries "task:t-1" table nil "")))
          (should (equal '(6 . 0) (completion-boundaries "@task:t-1" table nil "")))
          (should (test-completion "task:t-5e6f7a8b" table))
          (should (eq 'harness-compose-task (harness-ui-compose-test--category "task:" table))))
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "task:t-5e6f7a8b")))
          (harness-ui-compose-test--command 'harness-compose-add-attachment))
        (should (equal "ask @task:t-1a2b3c4d @task:t-5e6f7a8b " (harness-compose-text)))
        (should (equal (list fix docs) (mapcar (lambda (a) (plist-get a :task)) harness-compose-attachments)))
        ;; By its title: the candidates are the tasks, newest first.
        (harness-compose-remove-attachment (concat "task:" docs))
        (let ((offered nil))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt table &rest _)
                       (setq offered (all-completions "" table))
                       "t-5e6f7a8b  Write the docs  [pending]")))
            (harness-ui-compose-test--command 'harness-compose-attach-task))
          (should (equal '("t-5e6f7a8b  Write the docs  [pending]" "t-1a2b3c4d  Fix the login bug  [active]")
                         offered)))
        (should (equal (list fix docs) (mapcar (lambda (a) (plist-get a :task)) harness-compose-attachments)))
        ;; Sent, the references attach no file.
        (should (equal (list fix docs) (mapcar (lambda (a) (plist-get a :task)) (cdr (harness-compose-take)))))))))

(provide 'harness-ui-compose-test)
;;; harness-ui-compose-test.el ends here
