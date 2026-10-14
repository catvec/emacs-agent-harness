;;; harness-tools-question.el --- The ask_user tool: questions for the user  -*- lexical-binding: t; -*-

;;; Commentary:

;; `ask_user' blocks the turn on a pending question and resolves when a
;; UI answers it through `question/answer'.  Its options may each have
;; a diagram (ASCII art or an image), all of them or none.  An answer
;; may carry files the user attached to it, a screenshot its text names
;; as [image 1]: they reach the model with the answer, as a message of
;; the user's the waiting turn takes as steering.
;; `question/ask' asks the same kind of question for the harness
;; itself, with no tool call behind it (the cowboy module asks what to
;; do about a cold prompt cache this way).
;;
;; Nothing here waits: the continuations of unanswered questions live
;; in a `defvar' so a reload does not lose them.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(defvar harness-tools-question--questions (make-hash-table :test 'equal)
  "Pending id -> continuation of an unanswered question.
\(:session-id ID :resolve FN) for an ask_user call, whose FN takes the
tool result; (:session-id ID :on-answer FN) for a question the harness
asked itself (`question/ask'), whose FN takes the answer text and
whether it was dismissed.")

(defun harness-tools-question--pending-item (session-id pid)
  "Return the pending item PID of SESSION-ID, or nil."
  (cl-find pid (harness-call 'session/pending session-id)
           :key (lambda (it) (plist-get it :id)) :test #'equal))

;; An option is a string, or an object with a label and a diagram of the
;; answer: ASCII art (`diagram') or an image file (`image').  Either every
;; option has a diagram or none does, so the UI can show them in one
;; place and flip between them.  The pending question keeps the labels in
;; `:options', as before, and the diagrams in `:diagrams', one per option:
;; (:type "ascii" :text TEXT) or (:type "image" :path PATH :mime MIME).
;; An image travels as its path, never its data: pending items are saved
;; with the session and sent with every change to it.

(defconst harness-tools-question-image-types
  '(("png" . "image/png") ("jpg" . "image/jpeg") ("jpeg" . "image/jpeg")
    ("gif" . "image/gif") ("svg" . "image/svg+xml") ("webp" . "image/webp")
    ("bmp" . "image/bmp") ("tif" . "image/tiff") ("tiff" . "image/tiff"))
  "File extensions an ask_user image may have, with their MIME types.")

(defun harness-tools-question--invalid (format-string &rest args)
  "Reject the ask_user call: its result is the message FORMAT-STRING with ARGS."
  (throw 'harness-tools-question--invalid (apply #'format format-string args)))

(defun harness-tools-question--ascii-text (text)
  "Return ASCII diagram TEXT without blank lines or a Markdown fence around it.
The lines in between keep their indentation, which places the drawing."
  (let* ((trim (lambda (lines)
                 (dotimes (_ 2)
                   (while (and lines (string-blank-p (car lines))) (pop lines))
                   (setq lines (nreverse lines)))
                 lines))
         (lines (funcall trim (split-string (string-replace "\r" "" text) "\n"))))
    (when (and (cdr lines)
               (string-prefix-p "```" (string-trim-left (car lines)))
               (string-match-p "\\`[ \t]*```[ \t]*\\'" (car (last lines))))
      (setq lines (funcall trim (butlast (cdr lines)))))
    (mapconcat #'identity lines "\n")))

(defconst harness-tools-question-image-max-side 8000
  "Most pixels an ask_user image may have on a side.
Emacs draws no image larger than `max-image-size' allows, ten times its
frame by default, however small it would show it; and an image this
large shows so small beside the options that nothing in it can be read.")

(defun harness-tools-question--image (file n ctx)
  "Return the diagram of option N showing image FILE, relative to CTX's cwd."
  (let* ((path (harness-tools-resolve-path file ctx))
         (mime (cdr (assoc (downcase (or (file-name-extension path) "")) harness-tools-question-image-types))))
    (cond
     ((not mime)
      (harness-tools-question--invalid "Option %d: %s is not an image file; use a PNG, JPEG, GIF, SVG or WebP file, or an ASCII diagram"
                                    n file))
     ((not (and (file-regular-p path) (file-readable-p path)))
      (harness-tools-question--invalid "Option %d: image %s not found (cwd %s)" n file (plist-get ctx :cwd)))
     (t
      (let ((size (harness-image-pixel-size path)))
        (when (and size (> (max (car size) (cdr size)) harness-tools-question-image-max-side))
          (harness-tools-question--invalid
           "Option %d: image %s is %dx%d pixels, too large to show; crop it to the part the user should compare, or scale it down, to at most %d pixels on a side (about 600x400 shows best)"
           n file (car size) (cdr size) harness-tools-question-image-max-side)))
      (list :type "image" :path path :mime mime)))))

(defun harness-tools-question--option (item n ctx)
  "Return option ITEM, the Nth, of an ask_user call in CTX as (LABEL . DIAGRAM).
ITEM is a string, or an object (a plist) with `:label' and at most one
of `:diagram' (ASCII art) and `:image' (an image file).  DIAGRAM is nil
when ITEM has none."
  (if (stringp item)
      (cons item nil)
    (let* ((label (plist-get item :label))
           (ascii (plist-get item :diagram))
           (ascii (and (stringp ascii) (harness-tools-question--ascii-text ascii)))
           (ascii (and ascii (not (string-empty-p ascii)) ascii))
           (image (plist-get item :image))
           (image (and (stringp image) (not (string-blank-p image)) (string-trim image))))
      (unless (and (stringp label) (not (string-blank-p label)))
        (harness-tools-question--invalid "Option %d needs a label: the answer, as a string" n))
      (when (and ascii image)
        (harness-tools-question--invalid "Option %d has both a diagram and an image; give it one of them" n))
      (cons label (cond (ascii (list :type "ascii" :text ascii))
                        (image (harness-tools-question--image image n ctx)))))))

(defun harness-tools-question--numbers (numbers)
  "Return NUMBERS as words: \"2\", \"2 and 3\", \"1, 2 and 4\"."
  (let ((words (mapcar #'number-to-string numbers)))
    (if (cdr words)
        (concat (string-join (butlast words) ", ") " and " (car (last words)))
      (car words))))

(defun harness-tools-question--options (input ctx)
  "Return (LABELS . DIAGRAMS) for the options of ask_user INPUT in CTX.
DIAGRAMS is nil when no option has one, else a list with one per option.
Items that are neither strings nor objects are left out.  Throws the
message for the model to `harness-tools-question--invalid' when an option
is malformed, or when only some options have a diagram."
  (let* ((items (cl-remove-if-not (lambda (it) (or (stringp it) (and (consp it) (keywordp (car it)))))
                                  (append (plist-get input :options) nil)))
         (parsed (cl-loop for item in items for n from 1
                          collect (harness-tools-question--option item n ctx)))
         (missing (cl-loop for option in parsed for n from 1 unless (cdr option) collect n)))
    (when (and missing (< (length missing) (length parsed)))
      (harness-tools-question--invalid
       "Every option needs a diagram once one has: option%s %s ha%s none. Give each option a diagram or an image, or none of them a diagram"
       (if (cdr missing) "s" "") (harness-tools-question--numbers missing) (if (cdr missing) "ve" "s")))
    (cons (mapcar #'car parsed)
          (and parsed (not missing) (mapcar #'cdr parsed)))))

(defun harness-tools-question--ask-user (input ctx)
  "Handler of the ask_user tool: block on a pending question from INPUT in CTX.
A malformed call (see `harness-tools-question--options') returns an error
saying what to fix, and asks nothing."
  (let* ((sid (plist-get ctx :session-id))
         (question (or (plist-get input :question) ""))
         (free (if (plist-member input :allow_free_text)
                   (harness-json-true-p (plist-get input :allow_free_text))
                 t))
         (parsed (catch 'harness-tools-question--invalid
                   (harness-tools-question--options input ctx))))
    (if (stringp parsed)
        (harness-tool-error parsed)
      (harness-with-promise (resolve reject)
        (ignore reject)
        (let ((pid (harness-call 'session/pending-add sid
                                 (list :kind 'question
                                       :payload (append (list :question question :options (car parsed))
                                                        (and (cdr parsed) (list :diagrams (cdr parsed)))
                                                        (list :allow-free-text free
                                                              :call-id (plist-get ctx :call-id)))))))
          (puthash pid (list :session-id sid :resolve resolve) harness-tools-question--questions)
          (harness-emit 'question/asked sid (harness-tools-question--pending-item sid pid)))))))

(defun harness-tools-question--answer-text (answer)
  "Return the answer text from ANSWER, a string or a plist with `:answer'."
  (cond ((stringp answer) answer)
        ((and (listp answer) (plist-get answer :answer)) (format "%s" (plist-get answer :answer)))
        ((null answer) "")
        (t (format "%s" answer))))

(defun harness-tools-question--answer-blocks (answer)
  "Return the content blocks of the files the user attached to ANSWER, or nil.
That is a plist ANSWER's `:blocks', content blocks as `agent/prompt'
takes them: an image is (:type \"image\" :mime MIME :data BASE64), with
`:label' (image 1) when the answer's text names it by its token, [image
1].  One that is no block, with no `:type', is left out."
  (when (and (consp answer) (keywordp (car answer)))
    (let* ((blocks (plist-get answer :blocks))
           ;; A vector from a caller in this Emacs, an array not parsed.
           (blocks (if (vectorp blocks) (append blocks nil) blocks)))
      (and (proper-list-p blocks)
           (cl-remove-if-not (lambda (b) (and (consp b) (keywordp (car b)) (stringp (plist-get b :type))))
                             blocks)))))

(defun harness-tools-question--answer-without-blocks (answer)
  "Return ANSWER without its `:blocks', for the records and the event.
The session's pending list and `question/answered', which every client
hears, get the answer's text, never the bytes of the files attached."
  (if (and (consp answer) (keywordp (car answer)) (plist-member answer :blocks))
      (harness-plist-remove answer :blocks)
    answer))

(defun harness-tools-question--deliver-blocks (session-id blocks)
  "Send BLOCKS, the files attached to an answer, to SESSION-ID's model.
They go as a message of the user's that holds them alone, sent before
the answer settles its question: the turn waiting on the question takes
it as steering, so it reaches the model with the answer -- a hosted
loop gets its images with the ask_user result, a native one the message
right after that result (see `harness-agent--with-steering').  The
answer's text names an image by its token, [image 1], and the message
carries the image under that label, the token before it.  Only a
running turn is sent them, never one they would start on their own;
without the agent nothing is sent, and a failure to send is logged: the
answer goes all the same."
  (when (and blocks (harness-method-exists-p 'agent/prompt)
             (harness-method-exists-p 'agent/running)
             (harness-call 'agent/running session-id))
    (condition-case err
        (harness-call 'agent/prompt session-id blocks)
      (error (harness-log 'warn "tools-agent: sending the attachments of an answer in %s failed: %s"
                          session-id (harness-error-short-message err))))))

(defun harness-tools-question--settle-question (session-id pid answer &optional dismissed)
  "Resolve pending question PID of SESSION-ID with ANSWER.
DISMISSED non-nil says nobody answered: the question was dismissed.
The files ANSWER attached to an ask_user call's question go to the model
first, with it (`harness-tools-question--deliver-blocks').  Return non-nil
when a continuation was waiting."
  (let ((entry (gethash pid harness-tools-question--questions))
        (blocks (and (not dismissed) (harness-tools-question--answer-blocks answer)))
        (answer (harness-tools-question--answer-without-blocks answer)))
    (harness-call 'session/pending-resolve session-id pid answer)
    (when entry
      (remhash pid harness-tools-question--questions)
      (if (plist-get entry :on-answer)
          (funcall (plist-get entry :on-answer) (harness-tools-question--answer-text answer) dismissed)
        (harness-tools-question--deliver-blocks session-id blocks)
        (funcall (plist-get entry :resolve) (harness-tool-ok (harness-tools-question--answer-text answer))))
      (harness-emit 'question/answered session-id pid answer)
      t)))

(harness-defmethod question/answer (session-id pid answer)
  "Answer pending question PID of SESSION-ID with ANSWER.
ANSWER is a string or a plist (:answer STRING), with `:blocks' for the
files the user attached to the answer: content blocks as `agent/prompt'
takes them, an image's with its base64 `:data' and the `:label' its
token in the text names (image 1 for [image 1]).  The waiting ask_user
call returns the text as its result, and the files reach the model
with it, as a message of the user's that holds them, which the turn
takes with the answer (`harness-tools-question--deliver-blocks').  A
question the harness asked (`question/ask') gets the text alone.
Return non-nil when a question was waiting."
  (harness-tools-question--settle-question session-id pid answer))

(harness-defmethod question/cancel (session-id pid)
  "Dismiss pending question PID of SESSION-ID.
The waiting ask_user call returns \"The user dismissed the question\";
a question the harness asked (`question/ask') is told it was dismissed."
  (harness-tools-question--settle-question session-id pid "The user dismissed the question" t))

(harness-defmethod question/ask (session-id request on-answer)
  "Ask the user REQUEST's question in SESSION-ID for the harness; return its id.
This is ask_user's question without a tool call: the harness, not the
model, wants to know something before it goes on.  REQUEST is
\(:question TEXT :options LABELS :allow-free-text BOOL . MORE), as
ask_user's pending payload is; MORE goes into the payload as it is,
for the clients that know what it means (the cowboy module's `:cowboy',
say) -- the others show an ordinary question.  The question is pending
on SESSION-ID, which is blocked on it, and is answered as any other is,
with `question/answer' (UIs, ACP clients) or dismissed with
`question/cancel'.  ON-ANSWER is called once, then, with the answer's
text and a flag that is non-nil when the question was dismissed rather
than answered.  A question still waiting when the harness stops is gone
with the process, as an ask_user call's is."
  (let* ((options (append (plist-get request :options) nil))
         (payload (append (list :question (or (plist-get request :question) "")
                                :options options
                                :allow-free-text (if (plist-member request :allow-free-text)
                                                     (harness-json-true-p (plist-get request :allow-free-text))
                                                   t))
                          (harness-plist-remove request :question :options :allow-free-text)))
         (pid (harness-call 'session/pending-add session-id (list :kind 'question :payload payload))))
    (puthash pid (list :session-id session-id :on-answer on-answer) harness-tools-question--questions)
    (harness-emit 'question/asked session-id (harness-tools-question--pending-item session-id pid))
    pid))

(harness-defmethod question/pending (session-id)
  "Return the pending requests of SESSION-ID whose kind is `question'."
  (cl-remove-if-not (lambda (it) (eq (plist-get it :kind) 'question))
                    (harness-call 'session/pending session-id)))

(defconst harness-tools-question-image-max-bytes (* 16 1024 1024)
  "Largest image file, in bytes, `question/image' sends.")

(harness-defmethod question/image (session-id pid index)
  "Return the image of option INDEX of pending question PID of SESSION-ID.
INDEX counts from 0.  The value is (:mime MIME :data BASE64), the bytes
of the file the option shows, read here, where the harness runs: for a
client that cannot read them itself, such as a UI on another machine,
or one whose session works on a remote host.  Only an image of a
question still waiting is given.  Signal an error when there is none,
or the file cannot be read or is larger than
`harness-tools-question-image-max-bytes'."
  (let* ((item (harness-tools-question--pending-item session-id pid))
         (diagrams (and (eq (plist-get item :kind) 'question)
                        (append (plist-get (plist-get item :payload) :diagrams) nil)))
         (diagram (and (natnump index) (nth index diagrams)))
         (path (plist-get diagram :path)))
    (cond
     ((not item) (error "No question %s waits in session %s" pid session-id))
     ((not (and (equal (format "%s" (plist-get diagram :type)) "image") (stringp path)))
      (error "Option %s of question %s shows no image" index pid))
     ((not (and (file-regular-p path) (file-readable-p path)))
      (error "The image %s cannot be read any more" path))
     ((> (or (file-attribute-size (file-attributes path)) 0) harness-tools-question-image-max-bytes)
      (error "The image %s is larger than %s" path (file-size-human-readable harness-tools-question-image-max-bytes)))
     (t (list :mime (plist-get diagram :mime)
              :data (with-temp-buffer
                      (set-buffer-multibyte nil)
                      (insert-file-contents-literally path)
                      (base64-encode-region (point-min) (point-max) t)
                      (buffer-string)))))))

(harness-define-tool "ask_user"
  :label "Question"
  :description "Ask the user a question and wait for the answer. Use it when only the user can decide (ambiguous requirements, destructive choices, credentials). Offer options when there is a small set of sensible answers; the user may also type a free-form answer unless allow_free_text is false. When the options are easier to tell apart seen than described (layouts, architectures, data flows, UI sketches), give each option a diagram: ASCII art in diagram, or an image file in image. If one option has a diagram, every option must have one; the user flips between them in one place before answering. An image shows what ASCII art cannot, such as a mockup of a page or a chart: write an SVG with write_file, or save a screenshot of a mockup cropped to what differs between the options, in your temporary directory rather than the working directory, so it stays out of the work. Each image is shown at most about 400 pixels high, less in a small window, drawn on white as a browser shows it: draw about 600x400 with large text, and give an SVG a viewBox."
  :schema '(:type "object"
            :properties (:question (:type "string" :description "The question to ask.")
                         ;; Plain objects: the schema reaches every provider
                         ;; as it is, and not all of them may take anyOf.  A
                         ;; string is accepted too, as todo_write does.
                         :options (:type "array"
                                   :items (:type "object"
                                           :properties (:label (:type "string" :description "The answer, as the user reads it and as it is returned when picked.")
                                                        :diagram (:type "string" :description "ASCII diagram of this answer, shown in a fixed-width font.")
                                                        :image (:type "string" :description "Path of an image file (PNG, JPEG, GIF, SVG or WebP) showing this answer, instead of an ASCII diagram, such as an SVG you wrote in your temporary directory. A relative path is taken in the working directory."))
                                           :required ("label"))
                                   :description "Optional list of suggested answers, each with a label and, to compare them by sight, a diagram or an image illustrating it; a plain string is an option without one. If one option has a diagram or image, every option must have one.")
                         :allow_free_text (:type "boolean"
                                           :description "Whether a free-form answer is acceptable (default true)."))
            :required ("question"))
  :kind 'meta
  :timeout 86400
  :subject (lambda (input) (harness-first-line (plist-get input :question) 60))
  :handler #'harness-tools-question--ask-user)

(harness-declare-event 'question/asked "(SESSION-ID PENDING) after ask_user or `question/ask' added a pending question.")
(harness-declare-event 'question/answered "(SESSION-ID PENDING-ID ANSWER) after a question was answered or dismissed.")

(harness-define-module 'tools-question
  :doc "The Question tool (ask_user), and the questions the harness asks the user itself."
  :requires '(tools session))

(provide 'harness-tools-question)
;;; harness-tools-question.el ends here
