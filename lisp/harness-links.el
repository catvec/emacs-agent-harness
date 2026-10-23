;;; harness-links.el --- Links to sessions, messages, tool calls and review threads  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; How an agent points at something in the harness from its own words: a
;; session, a message or a tool call in one, a task, a thread of a task's
;; review.  Both sides of harness-server.el use it: the harness process
;; resolves a link and writes it out in full where the agent wrote it (the
;; `linking' module), and the UI draws and follows it (ui-linking).  This
;; file knows how a link reads and is written, and where one stands in
;; Markdown text; what it names is theirs to find.
;;
;; A link is a URL of the scheme `harness:'.  Its path is pairs of
;; KIND/REF, and only these shapes mean something:
;;
;;   harness:session/REF                  a session
;;   harness:session/REF/message/NODE     a message of that session
;;   harness:session/REF/call/NODE        a tool call of that session
;;   harness:session/REF/thread/THREAD    a thread of the review of its task
;;   harness:message/NODE                 a message of the session the text is in
;;   harness:call/CALL                    a tool call of the session the text is in
;;   harness:thread/THREAD                a thread of the review of that session's task
;;   harness:task/TASK                    a task
;;   harness:task/TASK/thread/THREAD      a thread of the review of that task
;;
;; The kinds also go by `msg' and `node' (a message), and `tool-call',
;; `tool_call' and `tool' (a call).  A REF is written as the harness names
;; things: a session by its id, a unique start of it, or its name; a
;; message or call by the id of its node (`n-...'), a call also by the id
;; the model's provider gave it.  A call or message of the session the
;; text is in may be named by a HANDLE instead, which means something
;; only where it is written (`harness-links-parse-handle'): `last', `first',
;; `#2', `bash#2', `user#1'.  Characters a URL cannot carry are written
;; %XX, as always.
;;
;; The link is written in Markdown as a link ([text](harness:...)), as an
;; autolink (<harness:...>), whose label the UI makes, or bare, where it
;; reads as one when it starts with a kind and goes on without a blank.
;; `harness-links-scan' finds them in a text the way the Markdown renderer
;; (harness-ui-markdown.el) does, leaving alone what that renders as code,
;; and `harness-links-rewrite' changes them in place.
;;
;; Nothing here asks the harness anything, so both sides can load it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-util)

(defconst harness-links-scheme "harness"
  "The URL scheme of a harness link, without its colon.")

(defconst harness-links--kinds
  '(("session" . session)
    ("message" . message) ("msg" . message) ("node" . message)
    ("call" . call) ("tool-call" . call) ("tool_call" . call) ("toolcall" . call) ("tool" . call)
    ("thread" . thread)
    ("task" . task))
  "The names a pair of a link path may start with, and the kind each means.")

(defun harness-links-p (string)
  "Return non-nil when STRING is written as a harness link.
That is only about how it starts, `harness:': it may still name nothing
\(`harness-links-parse' says)."
  (and (stringp string)
       (let ((case-fold-search t))
         (string-match-p "\\`harness:" string))))

;;;; Reading

(defun harness-links--decode (ref)
  "Return REF with its %XX escapes read as UTF-8."
  (if (string-search "%" ref)
      (condition-case nil
          (decode-coding-string (url-unhex-string ref) 'utf-8)
        (error ref))
    ref))

(defun harness-links--kind (name)
  "Return the kind NAME stands for, a symbol, or nil."
  (cdr (assoc (downcase name) harness-links--kinds)))

(defun harness-links-parse (url)
  "Return the plist URL reads as, or nil when it is no valid harness link.
The plist has `:kind', one of `session', `message', `call', `thread' and
`task', and what it names: `:session', `:message', `:call', `:task' and
`:thread', each the REF as written (decoded), the ones the link does not
name left out.  A message or call of the session the text is in has no
`:session'; so has a thread with no task or session.  `:message' is the
node's id, or a handle; so is `:call', and it may be the call's own id."
  (let ((case-fold-search t)
        (trimmed (and (stringp url) (string-trim url))))
    (when (and trimmed (string-match "\\`harness:/*\\(.*?\\)/*\\'" trimmed))
      (let* ((path (match-string 1 trimmed))
             (segments (and (not (string-empty-p path)) (split-string path "/"))))
        (when (and segments (cl-evenp (length segments))
                   (cl-notany #'string-empty-p segments))
          (let ((pairs (cl-loop for (name ref) on segments by #'cddr
                                collect (cons (harness-links--kind name)
                                              (harness-links--decode ref)))))
            (when (cl-every #'car pairs)
              (harness-links--shape pairs))))))))

(defun harness-links--shape (pairs)
  "Return the link plist for PAIRS, the (KIND . REF) of a path, or nil.\nNil when they are none of the shapes a link has."
  (pcase (mapcar #'car pairs)
    ('(session) (list :kind 'session :session (cdar pairs)))
    ('(session message) (list :kind 'message :session (cdar pairs) :message (cdadr pairs)))
    ('(session call) (list :kind 'call :session (cdar pairs) :call (cdadr pairs)))
    ('(session thread) (list :kind 'thread :session (cdar pairs) :thread (cdadr pairs)))
    ('(message) (list :kind 'message :message (cdar pairs)))
    ('(call) (list :kind 'call :call (cdar pairs)))
    ('(thread) (list :kind 'thread :thread (cdar pairs)))
    ('(task) (list :kind 'task :task (cdar pairs)))
    ('(task thread) (list :kind 'thread :task (cdar pairs) :thread (cdadr pairs)))))

(defun harness-links-parse-handle (ref)
  "Return the handle REF is, a plist, or nil when it is none.
A handle names a call or a message by where it stands among those of its
kind in a session, newest first: `last' (also `newest' and `latest') is
(:nth 1), `#3' is (:nth 3), `bash#2' is (:name \"bash\" :nth 2), the
second newest of the calls of the tool bash or, among messages, those of
the role `user' or `assistant'.  `first' (also `oldest') is (:first t).
Whoever resolves it knows what NAME means for the kind it looks among."
  (let ((case-fold-search t)
        (ref (and (stringp ref) (string-trim ref))))
    (cond
     ((null ref) nil)
     ((string-match-p "\\`\\(?:last\\|newest\\|latest\\)\\'" ref) (list :nth 1))
     ((string-match-p "\\`\\(?:first\\|oldest\\)\\'" ref) (list :first t))
     ((string-match "\\`\\(.*?\\)#\\([0-9]+\\)\\'" ref)
      ;; Both groups first: trimming runs a match of its own.
      (let* ((raw-name (match-string 1 ref))
             (n (string-to-number (match-string 2 ref)))
             (name (string-trim raw-name)))
        (and (>= n 1)
             (if (string-empty-p name) (list :nth n) (list :name name :nth n))))))))

;;;; Writing

(defun harness-links--encode (ref)
  "Return REF written as the path of a link carries it.
What a Markdown link, an autolink or a bare URL could not carry, and the
slash that parts a path, is written %XX."
  (replace-regexp-in-string
   "[^A-Za-z0-9_.~#:@+=&-]"
   (lambda (char)
     (mapconcat (lambda (byte) (format "%%%02X" byte)) (encode-coding-string char 'utf-8) ""))
   (format "%s" ref) t t))

(defun harness-links-url (link)
  "Return the URL of LINK, a plist as `harness-links-parse' returns one.
A thread with a task is written under the task, else under its session
when it has one, else alone.  Return nil when LINK names too little."
  (let* ((kind (plist-get link :kind))
         (enc (lambda (key) (let ((ref (plist-get link key)))
                              (and (stringp ref) (not (string-empty-p ref))
                                   (harness-links--encode ref)))))
         (session (funcall enc :session))
         (in (and session (concat "session/" session "/")))
         (thing (lambda (name key)
                  (when-let* ((ref (funcall enc key)))
                    (concat (or in "") name "/" ref)))))
    (when-let* ((path (pcase kind
                        ('session (and session (concat "session/" session)))
                        ('message (funcall thing "message" :message))
                        ('call (funcall thing "call" :call))
                        ('task (and (funcall enc :task) (concat "task/" (funcall enc :task))))
                        ('thread (when-let* ((thread (funcall enc :thread)))
                                   (cond ((funcall enc :task)
                                          (concat "task/" (funcall enc :task) "/thread/" thread))
                                         (session (concat "session/" session "/thread/" thread))
                                         (t (concat "thread/" thread))))))))
      (concat harness-links-scheme ":" path))))

(defun harness-links-session-url (session)
  "Return the URL of the session SESSION, a session id or another REF."
  (harness-links-url (list :kind 'session :session session)))

(defun harness-links-message-url (session node)
  "Return the URL of the message NODE of SESSION.\nA nil SESSION is the session the text is in."
  (harness-links-url (list :kind 'message :session session :message node)))

(defun harness-links-call-url (session node)
  "Return the URL of the tool call NODE of SESSION.\nA nil SESSION is the session the text is in."
  (harness-links-url (list :kind 'call :session session :call node)))

(defun harness-links-thread-url (task thread)
  "Return the URL of the thread THREAD of the review of TASK.\nA nil TASK is the task of the session the text is in."
  (harness-links-url (list :kind 'thread :task task :thread thread)))

(defun harness-links-task-url (task)
  "Return the URL of the task TASK."
  (harness-links-url (list :kind 'task :task task)))

(defun harness-links-markdown (label url)
  "Return the Markdown link to URL that reads LABEL.
Brackets in LABEL would end it early; they become parentheses."
  (format "[%s](%s)" (replace-regexp-in-string "\\[" "(" (replace-regexp-in-string "\\]" ")" label)) url))

(defun harness-links-label (link &optional name)
  "Return words that stand for LINK, a plist, when its author gave none.
NAME is what the link goes to is called, when the reader knows it: the
session's name, for a session link and the message or call in it."
  (let ((shorten (lambda (ref) (if (and (stringp ref) (> (length ref) 24))
                                   (concat (substring ref 0 22) "…")
                                 ref))))
    (pcase (plist-get link :kind)
      ('session (or name (format "session %s" (funcall shorten (plist-get link :session)))))
      ('message (format "message %s%s" (funcall shorten (plist-get link :message))
                        (if name (format " of %s" name) "")))
      ('call (format "tool call %s%s" (funcall shorten (plist-get link :call))
                     (if name (format " of %s" name) "")))
      ('thread (format "thread %s" (funcall shorten (plist-get link :thread))))
      ('task (or name (format "task %s" (funcall shorten (plist-get link :task)))))
      (_ "link"))))

;;;; Finding links in text

(defconst harness-links-bare-regexp
  (concat "harness:"
          "\\(?:session\\|message\\|msg\\|node\\|call\\|tool-call\\|tool_call\\|toolcall\\|tool\\|thread\\|task\\)"
          "/[A-Za-z0-9_~%#=&+@:/.-]+")
  "Regexp for a bare link: a URL that starts with a kind and has no blank in it.
It may take a full stop or a colon that closes a sentence with it, which
`harness-links-trim-bare' gives back.")

(defconst harness-links--reach 400
  "Most characters of the label and of the target of a link that are read.
The renderer reads a link of any length, but a text of thousands of
brackets with nothing to close them would send a match to the end of the
text from each, so what is searched for stays within reach.  A link
longer than this is a link all the same, and is left as it was written.")

(defconst harness-links--inline-regexp
  (rx-to-string
   `(or (group-n 1 "`" (+? (not "`")) "`")
        (seq "[" (group-n 2 (** 1 ,harness-links--reach (not "]")))
             "](" (group-n 3 (** 1 ,harness-links--reach (not ")"))) ")")
        (seq "<" (group-n 4 "harness:" (** 1 ,harness-links--reach (any alnum ":/._~?#=&%+@-"))) ">")
        (group-n 5 (regexp ,harness-links-bare-regexp)))
   t)
  "Regexp for what in a text may hold a harness link, as the renderer reads it.
Group 1 is a code span, which holds none; 2 and 3 the label and the target of
a Markdown link; 4 an autolink; 5 a bare link.")

(defun harness-links--fenced-ranges (text)
  "Return the (START . END) of the fenced code blocks of TEXT, in order.
A block runs from the line of its opening fence to the end of the line
of the closing one, as the renderer reads it: the same fence alone on
its line.  One that is never closed runs to the end of TEXT."
  (let ((ranges nil) (pos 0) (len (length text)))
    (while (< pos len)
      (let* ((eol (or (string-search "\n" text pos) len))
             (line (substring text pos eol)))
        (if (string-match "\\`[ ]\\{0,3\\}\\(```+\\|~~~+\\)" line)
            (let ((closing (concat "\\`[ ]\\{0,3\\}" (regexp-quote (match-string 1 line)) "[ ]*\\'"))
                  (start pos)
                  (next (min len (1+ eol)))
                  (closed nil))
              (while (and (< next len) (not closed))
                (let* ((end (or (string-search "\n" text next) len)))
                  (setq closed (string-match-p closing (substring text next end))
                        next (min len (1+ end)))))
              (push (cons start next) ranges)
              (setq pos next))
          (setq pos (min len (1+ eol))))))
    (nreverse ranges)))

(defun harness-links-trim-bare (text start end)
  "Return where the bare link TEXT has from START to END really ends.
A full stop or a colon that closes a sentence is not part of it."
  (while (and (> end start) (memq (aref text (1- end)) '(?. ?:)))
    (setq end (1- end)))
  end)

(defun harness-links-url-char-p (char)
  "Return non-nil when CHAR could be part of the URL of a bare link."
  (and char (or (<= ?a char ?z) (<= ?A char ?Z) (<= ?0 char ?9)
                (memq char '(?_ ?~ ?% ?# ?= ?& ?+ ?@ ?: ?/ ?. ?-)))))

(defun harness-links--scan-piece (text from to)
  "Return the harness links of TEXT between FROM and TO.\nThey are those `harness-links-scan' finds, with positions in TEXT."
  (let ((piece (substring text from to))
        (pos 0)
        (found nil))
    (while (string-match harness-links--inline-regexp piece pos)
      ;; Everything the match holds is read before any trimming runs a
      ;; match of its own.
      (let* ((start (match-beginning 0))
             (end (match-end 0))
             (code (match-beginning 1))
             (label (and (match-beginning 2) (match-string 2 piece)))
             (target (and (match-beginning 3) (match-string 3 piece)))
             (target-start (match-beginning 3))
             (auto (and (match-beginning 4) (match-string 4 piece)))
             (auto-start (match-beginning 4))
             (bare (match-beginning 5)))
        (cond
         (code)
         (target
          (let* ((lead (- (length target) (length (string-trim-left target))))
                 (url (string-trim target)))
            (when (harness-links-p url)
              (push (list :form 'link :start (+ from start) :end (+ from end)
                          :label label :url url
                          :url-start (+ from target-start lead)
                          :url-end (+ from target-start lead (length url)))
                    found))))
         (auto
          (push (list :form 'autolink :start (+ from start) :end (+ from end)
                      :url auto
                      :url-start (+ from auto-start) :url-end (+ from auto-start (length auto)))
                found))
         ;; Part of a longer word or address, not a link of its own.
         ((and bare (not (and (> start 0)
                              (harness-links-url-char-p (aref piece (1- start))))))
          (let ((stop (harness-links-trim-bare piece start end)))
            (setq end stop)
            (push (list :form 'bare :start (+ from start) :end (+ from stop)
                        :url (substring piece start stop)
                        :url-start (+ from start) :url-end (+ from stop))
                  found))))
        (setq pos (max end (1+ start)))))
    (nreverse found)))

(defun harness-links-scan (text)
  "Return the harness links in TEXT, in order, as plists.
Only those a Markdown renderer shows as links count, not what it shows
as code: a code span or a fenced block.  Each plist has `:form', `link'
\(for [label](URL), and the label in `:label'), `autolink' or `bare';
`:start' and `:end' for the whole link; `:url', its URL as written; and
`:url-start' and `:url-end', where the URL is in TEXT."
  (when (and (stringp text) (string-search "harness:" (downcase text)))
    (let ((found nil) (from 0))
      (dolist (fence (append (harness-links--fenced-ranges text)
                             (list (cons (length text) (length text)))))
        (when (< from (car fence))
          (setq found (nconc found (harness-links--scan-piece text from (car fence)))))
        (setq from (max from (cdr fence))))
      found)))

(defun harness-links-rewrite (text function)
  "Return TEXT with the harness links FUNCTION changes.
FUNCTION is called with each link `harness-links-scan' finds, and
returns nil to leave it, or a string to put in place of its URL -- of
the whole link when it is bare, which has no more than a URL."
  (let ((out nil) (pos 0))
    (dolist (link (harness-links-scan text))
      (let ((new (funcall function link))
            (from (plist-get link :url-start))
            (to (plist-get link :url-end)))
        (when (and (stringp new) (not (string= new (substring text from to))))
          (push (substring text pos from) out)
          (push new out)
          (setq pos to))))
    (if (null out)
        text
      (push (substring text pos) out)
      (apply #'concat (nreverse out)))))

(provide 'harness-links)
;;; harness-links.el ends here
